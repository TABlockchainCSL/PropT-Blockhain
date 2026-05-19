// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/governance/Governor.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title PropertyGovernor
 * @notice DAO governance contract for PropertyToken holders. Enables
 *         decentralized decision-making on property management through
 *         on-chain voting with timelock-enforced execution.
 *
 * @dev Architecture decisions (from research):
 *      - OpenZeppelin Governor: Battle-tested, modular framework derived
 *        from Compound Governor Alpha/Bravo (Santana & Albareda, 2022).
 *      - On-chain voting: All votes are recorded on the blockchain ledger,
 *        enabling trustless verification and OJK audit compliance
 *        (Avci & Erzurumlu, 2023).
 *      - GovernorVotes: Extracts voting power from ERC20Votes checkpoints,
 *        preventing flash loan voting manipulation (Fritsch et al., 2022).
 *      - TimelockControl: 48-hour delay after proposal approval gives
 *        minority investors time to exit before execution
 *        (Santana & Albareda, 2022).
 *      - GovernorVotesQuorumFraction(4): 4% quorum — cukup rendah agar
 *        proposal realistis lolos (investor ritel pada umumnya pasif,
 *        partisipasi voting rata-rata hanya 5-10%), namun cukup tinggi
 *        untuk mencegah manipulasi oleh segelintir pemegang token.
 *
 * @dev Proposal Access Control:
 *      - HANYA proposerAdmin yang bisa mengajukan proposal.
 *      - Keputusan desain ini berdasarkan:
 *        1. Kepatuhan OJK: Platform harus menunjukkan kontrol atas aksi korporasi
 *        2. Keamanan: Mencegah proposal berbahaya (calldata exploit)
 *        3. Jaminan Dana: Admin memverifikasi dana sudah tersedia sebelum propose
 *      - Investor tetap punya suara melalui voting (castVote)
 *      - Admin path tetap tersedia sebagai fallback
 *
 * Lifecycle: propose (admin only) → votingDelay → castVote → votingPeriod →
 *            queue (timelock) → minDelay → execute
 *
 * Liquidation Flow (Jual Properti):
 *  1. Admin verifikasi dana penjualan sudah diterima off-chain
 *  2. Admin propose likuidasi via Governor
 *  3. Investor vote (4% quorum, >50% majority)
 *  4. Jika disetujui → execute via Timelock:
 *     a. DividendDistribution.depositDividends(hasilPenjualan)
 *     b. PropertyRegistry.deactivateProperty(propertyId)
 *  5. Investor klaim dividen terakhir
 *  6. Investor burn token masing-masing (ERC20Burnable)
 */
contract PropertyGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    // ── Admin (hanya bisa propose) ───────────────────────────────────
    /// @notice Address yang berhak mengajukan proposal
    address public immutable proposerAdmin;

    // ── Proposal Document Storage ────────────────────────────────────
    /// @notice IPFS document URI per proposal (e.g. legal docs, reports)
    mapping(uint256 => string) public proposalDocuments;

    // ── Events ───────────────────────────────────────────────────────
    /// @notice Emitted when a proposal is created with an IPFS document
    event ProposalDocumentSet(
        uint256 indexed proposalId,
        string ipfsDocumentURI
    );

    // ── Errors ───────────────────────────────────────────────────────
    /// @notice Caller is not the proposer admin
    error OnlyProposerAdmin(address caller, address expected);
    /// @notice Empty IPFS document URI
    error EmptyDocumentURI();

    // ── Constructor ───────────────────────────────────────────────────
    /**
     * @param token_         PropertyToken address (implements IVotes)
     * @param timelock_      TimelockController instance
     * @param proposerAdmin_ Address yang berhak propose
     */
    constructor(
        IVotes token_,
        TimelockController timelock_,
        address proposerAdmin_
    )
        Governor("PropertyGovernor")
        GovernorSettings(
            43200,  // votingDelay  = 1 day  (86400s / 2s per block on Base)
            302400, // votingPeriod = 7 days (604800s / 2s per block on Base)
            0       // proposalThreshold = 0 (akses dikontrol oleh onlyProposerAdmin)
        )
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(4)  // 4% of total supply must participate
        GovernorTimelockControl(timelock_)
    {
        require(proposerAdmin_ != address(0), "Governor: zero proposer admin");
        proposerAdmin = proposerAdmin_;
    }


    // ═══════════════════════════════════════════════════════════════════
    //  Proposal Access Control — Only Admin Can Propose
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Override propose to restrict access to proposerAdmin only.
     * @dev Trade-off: mengorbankan desentralisasi penuh demi kepatuhan
     *      OJK Sandbox dan jaminan verifikasi dana. Investor tetap
     *      punya suara melalui castVote().
     */
    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(Governor) returns (uint256) {
        if (msg.sender != proposerAdmin) {
            revert OnlyProposerAdmin(msg.sender, proposerAdmin);
        }
        return super.propose(targets, values, calldatas, description);
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Proposal with IPFS Document
    // ═══════════════════════════════════════════════════════════════════

    /**
     * @notice Create a proposal with an attached IPFS document URI.
     *         The document can contain legal analysis, property appraisal,
     *         sale agreement, or any supporting documentation.
     *
     * @dev Only callable by proposerAdmin (enforce via propose() override)
     *
     * @param targets         Target contract addresses
     * @param values          ETH values for each call
     * @param calldatas       Encoded function calls
     * @param description     Human-readable proposal description
     * @param ipfsDocumentURI IPFS CID/URI for supporting documents
     * @return proposalId     The created proposal's ID
     */
    function proposeWithDocument(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description,
        string memory ipfsDocumentURI
    ) public returns (uint256) {
        if (bytes(ipfsDocumentURI).length == 0) revert EmptyDocumentURI();

        // Create the proposal using propose() — admin check enforced there
        uint256 proposalId = propose(targets, values, calldatas, description);

        // Store the IPFS document URI
        proposalDocuments[proposalId] = ipfsDocumentURI;
        emit ProposalDocumentSet(proposalId, ipfsDocumentURI);

        return proposalId;
    }

    /**
     * @notice Get the IPFS document URI for a given proposal.
     * @param proposalId The proposal ID
     * @return The IPFS document URI (empty string if none attached)
     */
    function getProposalDocument(
        uint256 proposalId
    ) public view returns (string memory) {
        return proposalDocuments[proposalId];
    }

    // ═══════════════════════════════════════════════════════════════════
    //  Override Resolution (Solidity multiple inheritance)
    // ═══════════════════════════════════════════════════════════════════

    function votingDelay()
        public view override(Governor, GovernorSettings)
        returns (uint256)
    { return super.votingDelay(); }

    function votingPeriod()
        public view override(Governor, GovernorSettings)
        returns (uint256)
    { return super.votingPeriod(); }

    function quorum(uint256 blockNumber)
        public view override(Governor, GovernorVotesQuorumFraction)
        returns (uint256)
    { return super.quorum(blockNumber); }

    function proposalThreshold()
        public view override(Governor, GovernorSettings)
        returns (uint256)
    { return super.proposalThreshold(); }

    function state(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl)
        returns (ProposalState)
    { return super.state(proposalId); }

    function proposalNeedsQueuing(uint256 proposalId)
        public view override(Governor, GovernorTimelockControl)
        returns (bool)
    { return super.proposalNeedsQueuing(proposalId); }

    function _queueOperations(
        uint256 proposalId, address[] memory targets,
        uint256[] memory values, bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(
            proposalId, targets, values, calldatas, descriptionHash
        );
    }

    function _executeOperations(
        uint256 proposalId, address[] memory targets,
        uint256[] memory values, bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(
            proposalId, targets, values, calldatas, descriptionHash
        );
    }

    function _cancel(
        address[] memory targets, uint256[] memory values,
        bytes[] memory calldatas, bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor()
        internal view override(Governor, GovernorTimelockControl)
        returns (address)
    { return super._executor(); }
}
