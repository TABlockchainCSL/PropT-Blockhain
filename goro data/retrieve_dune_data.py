import os
from pathlib import Path

import requests
from dotenv import load_dotenv


load_dotenv(Path(__file__).with_name(".env"))

QUERY_ID = 6936221
OUTPUT_FILE = Path(__file__).with_name(f"dune_query_{QUERY_ID}.csv")

api_key = os.getenv("DUNE_API_KEY")
if not api_key:
    raise RuntimeError("DUNE_API_KEY is missing from your .env file")

url = f"https://api.dune.com/api/v1/query/{QUERY_ID}/results/csv"
headers = {"X-Dune-API-Key": api_key}

try:
    with requests.get(url, headers=headers, timeout=120, stream=True) as response:
        response.raise_for_status()

        with OUTPUT_FILE.open("wb") as file:
            for chunk in response.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    file.write(chunk)

    print(f"CSV saved to: {OUTPUT_FILE.resolve()}")
except requests.HTTPError as error:
    print(f"Dune API error: {error}")
    print(error.response.text)
except requests.RequestException as error:
    print(f"Request failed: {error}")
