import os
import re

def refactor_file(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # 1. Replace kycRegistry.addUser(addr, LEVEL) -> kycRegistry.addUser(addr)
    content = re.sub(r'kycRegistry\.addUser\(([^,]+),\s*[^)]+\)', r'kycRegistry.addUser(\1)', content)

    # 2. Replace kycRegistry.getKYCLevel(addr) ==/!= X -> kycRegistry.isVerified(addr)
    # E.g. assertEq(kycRegistry.getKYCLevel(user1), KYC_LEVEL_BASIC); -> assertTrue(kycRegistry.isVerified(user1));
    content = re.sub(r'assertEq\(kycRegistry\.getKYCLevel\(([^)]+)\),\s*[^)]+\);', r'assertTrue(kycRegistry.isVerified(\1));', content)
    content = re.sub(r'assertEq\(kycRegistry\.getKYCLevel\(([^)]+)\),\s*0\);', r'assertFalse(kycRegistry.isVerified(\1));', content)
    
    # 3. Remove requiredKYCLevel from PropertyTokenFactory.CreateTokenParams
    content = re.sub(r'^\s*requiredKYCLevel:\s*[^,]+,?\n', '', content, flags=re.MULTILINE)
    content = re.sub(r'^\s*p\d*\.requiredKYCLevel\s*=\s*[^;]+;\n', '', content, flags=re.MULTILINE)

    # 4. Remove _deployToken(KYC_LEVEL_...) -> _deployToken()
    content = re.sub(r'_deployToken\([^)]+\)', r'_deployToken()', content)

    # 5. Remove test_KYC_batchAddUsers and related tests
    # Actually, we can just delete the whole function definition and body.
    # It might be easier to do manual replacement for the big test blocks if regex is too risky.
    
    with open(filepath, 'w') as f:
        f.write(content)

test_files = [
    "test/PropertyTokenization.t.sol",
    "test/Governance.t.sol",
    "test/Security.t.sol",
    "test/PauserAndFactoryACL.t.sol",
    "test/Fuzz.t.sol",
    "test/Invariant.t.sol",
    "test/handlers/Handler.sol"
]

for f in test_files:
    if os.path.exists(f):
        refactor_file(f)
        print(f"Refactored {f}")
