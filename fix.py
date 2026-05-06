import re
import sys

with open(sys.argv[1], 'r') as f:
    text = f.read()

def revert_longtable(match):
    content = match.group(0)
    # Extract pieces
    # We know the broken format is:
    # \begingroup
    # \small (optional)
    # \begin{longtable}{COL_FORMAT_BROKEN
    # \caption{CAPTION}
    # \label{LABEL} \\
    # HEADER_AND_BODY
    
    # We want to restore back to:
    # \begin{table}[H]
    # \centering
    # \caption{CAPTION}
    # \label{LABEL}
    # \small
    # \begin{tabular}{COL_FORMAT}
    # HEADER_AND_BODY
    # \end{tabular}
    # \end{table}
    
    pass

