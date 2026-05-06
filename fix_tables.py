import re
import sys

def fix_tabulars(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    def replace_func(match):
        start = match.group(1)
        spec = match.group(2).strip()
        toprule = match.group(3)
        rest = match.group(4)
        
        # Heuristic to find the missing columns based on headers
        # We look for the first row after \toprule or \midrule
        # and count the number of '&'
        
        first_row = rest.split('\\midrule')[0].split('\\\\')[0]
        num_cols = first_row.count('&') + 1
        
        # If spec is just one column like p{3cm} but headers have more
        current_cols = re.findall(r'[clrpPBLUCORTE]\{[^}]*\}|[clrp]', spec)
        
        if len(current_cols) < num_cols:
            # We need to add columns. We'll use p{2.5cm} as a default for missing ones
            # or try to be smarter
            needed = num_cols - len(current_cols)
            new_spec = spec + ("p{2.5cm}" * needed)
            return f"\\begin{{tabular}}{{{new_spec}}}\n{toprule}"
        
        return match.group(0)

    # Match \begin{tabular}{spec} \n \toprule
    # The bug is that spec is truncated and \toprule is on the next line
    pattern = re.compile(r'\\begin\{tabular\}\{([^}\n]*)\n\s*(\\toprule)', re.DOTALL)
    
    # Actually, let's just join the lines first
    new_content = re.sub(r'(\\begin\{tabular\}\{[^}]*)\n\s*(\\toprule)', r'\1}\n\2', content)
    
    # Now fix the missing braces if any
    # (The previous sed might have left \begin{tabular}{p{3cm} \toprule)
    
    with open(filepath, 'w') as f:
        f.write(new_content)

if __name__ == "__main__":
    fix_tabulars(sys.argv[1])
