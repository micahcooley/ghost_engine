#!/usr/bin/env bash
set -e

if [ -z "$1" ]; then
  echo "Usage: $0 <secondary_drive_path>"
  exit 1
fi

SECONDARY_DRIVE="$1"
CORPUS_ROOT="$SECONDARY_DRIVE/corpus_data"
WIKI_DIR="$CORPUS_ROOT/wikipedia"
DOCS_DIR="$CORPUS_ROOT/dev_docs"

echo "[*] Creating Omni-Codex directories at $CORPUS_ROOT"
mkdir -p "$WIKI_DIR"
mkdir -p "$DOCS_DIR"

if [ -n "$GHOST_DUMMY_FETCH" ]; then
  echo "[*] DUMMY_MODE enabled. Directories created. Skipping downloads."
  exit 0
fi

echo "[*] Starting parallel downloads for Omni-Codex..."

# 1. Wikipedia
(
  echo "[*] Fetching and extracting Wikipedia dump..."
  # Download and stream directly to wikiextractor (if available) to save disk space
  if command -v python3 &>/dev/null && python3 -c "import wikiextractor" 2>/dev/null; then
    wget -qO- https://dumps.wikimedia.org/enwiki/latest/enwiki-latest-pages-articles.xml.bz2 | \
      python3 -m wikiextractor.WikiExtractor -o "$WIKI_DIR" --processes $(nproc) -q -
  else
    echo "[!] wikiextractor not found. Saving compressed dump..."
    wget -q -c https://dumps.wikimedia.org/enwiki/latest/enwiki-latest-pages-articles.xml.bz2 -O "$WIKI_DIR/enwiki-latest-pages-articles.xml.bz2"
  fi
) &

# 2. Dev Docs (Zig, Python, C, C++, C#, TypeScript, JavaScript, HTML, CSS, Intel x86/ARM)
fetch_dev_doc() {
  local name=$1
  local url=$2
  echo "[*] Fetching dev doc: $name..."
  local ext="${url##*.}"
  local filename="$name.$ext"
  if [[ "$url" == *.tar.gz ]]; then filename="$name.tar.gz"; fi
  if [[ "$url" == *.tar.bz2 ]]; then filename="$name.tar.bz2"; fi
  if [[ "$url" == *.zip ]]; then filename="$name.zip"; fi
  
  wget -q -c "$url" -O "$DOCS_DIR/$filename" || { echo "[!] Failed to fetch $name"; return 1; }
  
  echo "[*] Extracting $name..."
  mkdir -p "$DOCS_DIR/$name"
  if [[ "$filename" == *.tar.gz || "$filename" == *.tgz ]]; then
    tar -xzf "$DOCS_DIR/$filename" -C "$DOCS_DIR/$name" --strip-components=1 2>/dev/null || true
  elif [[ "$filename" == *.tar.bz2 ]]; then
    tar -xjf "$DOCS_DIR/$filename" -C "$DOCS_DIR/$name" --strip-components=1 2>/dev/null || true
  elif [[ "$filename" == *.zip ]]; then
    unzip -q "$DOCS_DIR/$filename" -d "$DOCS_DIR/$name" 2>/dev/null || true
  fi
}

(fetch_dev_doc "zig" "https://github.com/ziglang/zig/archive/refs/heads/master.tar.gz") &
(fetch_dev_doc "python" "https://docs.python.org/3/archives/python-3.13-docs-text.tar.bz2") &
(fetch_dev_doc "typescript" "https://github.com/microsoft/TypeScript/archive/refs/heads/main.tar.gz") &
(fetch_dev_doc "javascript" "https://github.com/mdn/content/archive/refs/heads/main.tar.gz") &
(fetch_dev_doc "html" "https://github.com/mdn/content/archive/refs/heads/main.tar.gz") &
(fetch_dev_doc "css" "https://github.com/mdn/content/archive/refs/heads/main.tar.gz") &
(fetch_dev_doc "c" "https://github.com/cplusplus/draft/archive/refs/heads/main.tar.gz") &
(fetch_dev_doc "cpp" "https://github.com/cplusplus/draft/archive/refs/heads/main.tar.gz") &
(fetch_dev_doc "csharp" "https://github.com/dotnet/csharplang/archive/refs/heads/main.tar.gz") &
(fetch_dev_doc "intel_x86" "https://github.com/hjlebbink/asm-dude/archive/refs/heads/master.zip") &
(fetch_dev_doc "arm" "https://github.com/ARM-software/abi-aa/archive/refs/heads/main.tar.gz") &

wait
echo "[*] Omni-Codex fetch complete!"
