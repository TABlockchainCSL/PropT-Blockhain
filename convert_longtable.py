import re
import sys

def convert_to_longtable(match):
    full_text = match.group(0)
    
    # Extract parts
    caption_match = re.search(r'\\caption\{(.*?)\}', full_text)
    label_match = re.search(r'\\label\{(.*?)\}', full_text)
    size_match = re.search(r'\\(small|footnotesize|scriptsize|tiny)', full_text)
    tabular_match = re.search(r'\\begin\{tabular\}\{(.*?)\}(.*?)\\end\{tabular\}', full_text, re.DOTALL)
    
    if not (caption_match and label_match and tabular_match):
        return full_text
        
    caption = caption_match.group(1)
    label = label_match.group(1)
    size_cmd = size_match.group(1) if size_match else ""
    col_format = tabular_match.group(1)
    content = tabular_match.group(2)
    
    # Extract header (everything up to \midrule)
    header_match = re.search(r'(.*?\\midrule\s*)', content, re.DOTALL)
    if header_match:
        header = header_match.group(1).strip()
        body = content[len(header_match.group(1)):].strip()
    else:
        header = ""
        body = content.strip()
        
    num_cols = len([c for c in col_format if c in 'lrcpX'])
    
    res = []
    res.append(r"\begingroup")
    if size_cmd:
        res.append(f"\\{size_cmd}")
    res.append(f"\\begin{{longtable}}{{{col_format}}}")
    res.append(f"\\caption{{{caption}}}")
    res.append(f"\\label{{{label}}} \\\\")
    res.append(header)
    res.append(r"\endfirsthead")
    res.append(f"\\multicolumn{{{num_cols}}}{{c}}{{{{\\tablename\\ \\thetable\\ -- Lanjutan dari halaman sebelumnya}}}} \\\\")
    res.append(header)
    res.append(r"\endhead")
    res.append(r"\midrule")
    res.append(f"\\multicolumn{{{num_cols}}}{{r}}{{\\textit{{Bersambung ke halaman berikutnya}}}} \\\\")
    res.append(r"\endfoot")
    res.append(r"\bottomrule")
    res.append(r"\endlastfoot")
    res.append(body.replace(r"\bottomrule", "").strip())
    res.append(r"\end{longtable}")
    res.append(r"\endgroup")
    
    return "\n".join(res)

with open(sys.argv[1], 'r') as f:
    text = f.read()

pattern = re.compile(r'\\begin\{table\}\[H\].*?\\end\{table\}', re.DOTALL)
new_text = pattern.sub(convert_to_longtable, text)

with open(sys.argv[1], 'w') as f:
    f.write(new_text)

print("Done")
