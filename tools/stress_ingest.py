#!/usr/bin/env python3
import os
import sys
import time
import mmap
import struct
import random

LATTICE_PATH = "/tmp/ghost_lattice_stress.bin"
NUM_TOKENS = 50000
VECTOR_BYTES = 128
HEADER_FORMAT = "<4sIII" # magic, version, count, capacity
HEADER_SIZE = struct.calcsize(HEADER_FORMAT)

def stress_ingest():
    # Ensure lattice exists and has capacity
    capacity = 100000
    file_size = HEADER_SIZE + (capacity * VECTOR_BYTES)
    
    if not os.path.exists(LATTICE_PATH):
        with open(LATTICE_PATH, "wb") as f:
            f.truncate(file_size)
            header = struct.pack(HEADER_FORMAT, b'LATT', 1, 0, capacity)
            f.write(header)

    start_time = time.time()
    
    with open(LATTICE_PATH, "r+b") as f:
        mm = mmap.mmap(f.fileno(), 0, access=mmap.ACCESS_WRITE)
        
        magic, version, count, cap = struct.unpack_from(HEADER_FORMAT, mm, 0)
        
        for i in range(NUM_TOKENS):
            if count >= cap:
                print("Capacity reached!")
                break
                
            # Generate random 1024-bit vector (128 bytes)
            # In a real scenario, this is the context vector from Neural IPC Bridge
            vector = os.urandom(VECTOR_BYTES)
            
            # Simulated Semantic Resonance Fallback:
            # We skip the O(N) scan here for the pure ingest benchmark to test raw write speed.
            # Append directly
            offset = HEADER_SIZE + (count * VECTOR_BYTES)
            mm[offset:offset+VECTOR_BYTES] = vector
            
            count += 1
            
        # Update header
        struct.pack_into(HEADER_FORMAT, mm, 0, b'LATT', version, count, cap)
        mm.close()

    duration = time.time() - start_time
    print(f"Ingested {NUM_TOKENS} tokens in {duration:.4f} seconds.")
    if duration > 5.0:
        print("FAILED: Took longer than 5 seconds.")
        sys.exit(1)
    print("SUCCESS: Ingest is under 5 seconds.")

if __name__ == "__main__":
    stress_ingest()
