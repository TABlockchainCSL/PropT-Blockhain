import re
import sys

def convert_to_longtable(filepath):
    with open(filepath, 'r') as f:
        content = f.read()

    # Pattern to match the table blocks I just created
    # \begin{table}[H]
    # \centering
    # \caption{...}
    # \label{...}
    # \small (optional)
    # \begin{tabular}{cols}
    # body
    # \end{tabular}
    # \end{table}
    
    table_pattern = re.compile(
        r'\\begin\{table\}\[H\]\s*\\centering\s*\\caption\{(?P<caption>.*?)\}\s*\\label\{(?P<label>.*?)\}\s*(?P<size>\\small|\\footnotesize)?\s*\\begin\{tabular\}\{(?P<cols>.*?)\}\s*(?P<body>.*?)\\end\{tabular\}\s*\\end\{table\}',
        re.DOTALL
    )

    def replace_table(match):
        caption = match.group('caption')
        label = match.group('label')
        size = match.group('size') or ''
        cols = match.group('cols')
        body = match.group('body').strip()
        
        # Determine number of columns for multicolumn
        # Count & in the first non-empty line of the body
        first_row = ""
        for line in body.split('\n'):
            if '&' in line:
                first_row = line
                break
        num_cols = first_row.count('&') + 1
        
        # Extract headers (between toprule and midrule)
        header_match = re.search(r'\\toprule(.*?)\\midrule', body, re.DOTALL)
        headers = header_match.group(1).strip() if header_match else ""
        
        # The content after midrule
        actual_body = body.split('\\midrule')[-1].strip()
        
        res = []
        if size:
            res.append(size)
        res.append(f"\\begin{{longtable}}{{{cols}}}")
        res.append(f"\\caption{{{caption}}} \\label{{{label}}} \\\\")
        res.append(f"\\toprule")
        res.append(headers)
        res.append(f"\\\\ \\midrule")
        res.append(f"\\endfirsthead")
        res.append(f"")
        res.append(f"\\multicolumn{{{num_cols}}}{{c}}{{\\tablename\\ \\thetable\\ (sambungan)}} \\\\")
        res.append(f"\\toprule")
        res.append(headers)
        res.append(f"\\\\ \\midrule")
        res.append(f"\\endhead")
        res.append(f"")
        res.append(actual_body)
        res.append(f"\\end{{longtable}}")
        
        return "\n".join(res)

    new_content = table_pattern.sub(replace_table, content)
    
    with open(filepath, 'w') as f:
        f.write(new_content)

if __name__ == "__main__":
    convert_to_longtable(sys.argv[1])
