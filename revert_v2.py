import re
import sys

def revert_longtable(match):
    full_text = match.group(0)
    
    size_match = re.search(r'\\(small|footnotesize|scriptsize|tiny)', full_text)
    size_cmd = size_match.group(1) if size_match else ""
    
    col_match = re.search(r'\\begin\{longtable\}\{(.*?)\}', full_text, re.DOTALL)
    cols = col_match.group(1).replace('\n', '') if col_match else ""
    
    caption_match = re.search(r'\\caption\{(.*?)\}', full_text)
    caption = caption_match.group(1) if caption_match else ""
    
    label_match = re.search(r'\\label\{(.*?)\}', full_text)
    label = label_match.group(1) if label_match else ""
    
    # Extract body: it might have \endlastfoot if it was fully generated, or just regular tabular content
    if '\\endlastfoot' in full_text:
        body_match = re.search(r'\\endlastfoot\s*(.*?)\\end\{longtable\}', full_text, re.DOTALL)
        body = body_match.group(1) if body_match else ""
    else:
        # Just extract everything between \toprule (or \midrule) and \bottomrule
        body_match = re.search(r'\\toprule(.*?)\\bottomrule', full_text, re.DOTALL)
        body = body_match.group(1) if body_match else ""
        if body:
             body = "\\toprule" + body + "\\bottomrule"
    
    # Header logic if it has endfirsthead
    if '\\endfirsthead' in full_text:
        header_match = re.search(r'\\label\{.*?\}\s*\\\\\s*(.*?)\\endfirsthead', full_text, re.DOTALL)
        header = header_match.group(1).strip() if header_match else ""
    else:
        header = ""
        
    if not body and not header:
        # Fallback: just grab everything after label or \toprule
        body_match = re.search(r'(\\toprule.*?\\bottomrule)', full_text, re.DOTALL)
        body = body_match.group(1) if body_match else ""
    elif not body and header:
        pass # Handle this?
        
    res = []
    res.append(r"\begin{table}[H]")
    res.append(r"\centering")
    res.append(f"\\caption{{{caption}}}")
    res.append(f"\\label{{{label}}}")
    if size_cmd:
        res.append(f"\\{size_cmd}")
    res.append(f"\\begin{{tabular}}{{{cols}}}")
    if header and '\\toprule' not in body:
        res.append(header)
    res.append(body.strip())
    res.append(r"\end{tabular}")
    res.append(r"\end{table}")
    
    return "\n".join(res)

with open(sys.argv[1], 'r') as f:
    text = f.read()

# Pattern to match optional { \size \begin{longtable} ... \end{longtable} }
pattern = re.compile(r'\{?\s*\\(?:small|footnotesize|scriptsize|tiny)?\s*\\begin\{longtable\}.*?\\end\{longtable\}\s*\}?', re.DOTALL)
new_text = pattern.sub(revert_longtable, text)

with open(sys.argv[1], 'w') as f:
    f.write(new_text)

print("Done")
