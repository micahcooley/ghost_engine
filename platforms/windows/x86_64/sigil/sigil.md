# The Sigil Language Specification
**Version:** 2.1 (Orthogonal CMS & Persistent I/O)
**Target:** Bare-Metal AI Logic Manipulation

---

## Abstract
Sigil is a Domain-Specific Language (DSL) designed exclusively for the Ghost Engine. It does not compile to machine code. It compiles to physical memory addresses, `u4` energy gradients, and hyperdimensional `VSA` bindings. 

The Unified Sigil Design treats all AI memory operations as hitting one of two internal systems, routed automatically by explicit targets:
1. **Canvas ops:** Raw byte writes to a `.bin` file (`fluent`, `deep1`, `deep2`).
2. **VSA ops:** Hypervector algebra using roles and semantic binding.

---

## Part I: The Unified Verb Set (V2.1)

Every operation in Sigil uses a single intention verb, requires explicit targets, and leaves no ambiguity.

| Verb | Replaces | What it does |
|---|---|---|
| `ETCH` | `WRITE` / `INJECT` | Orthogonal CMS write, concept + weight. |
| `TEST` | `PROBE` / `READ` | CMS interrogate: `TEST "txt" -> var`. |
| `LOCK` | `INJECT .. AS ROLE` | VSA hypervector binding: `key :: value`. |
| `BIND` | `OPEN` | Memory-map a canvas: `BIND "file.bin"`. |
| `VOID` | `SEVER` | Hard kill, zeroes the 4-way CMS slots. |
| `SCAN` | `PEEK` | Print energy gradient to console. |
| `LET` | `LET` | Variable assignment (u16). |
| `LOOM` | `LOOM` | Context-scoped block (VAR or MOOD gate). |

---

## Part II: The Syntax Rules

### 1. Canvas Binding
Scripts must bind a canvas before etching. The handle is persistent.
```sigil
BIND "fluent.bin";
BIND "deep2.bin" AS deep2;
```

### 2. CMS Interrogation with `TEST`
Unlike V2.0 which had no read-back, V2.1 uses `TEST` to assign energy levels to variables.
```sigil
TEST "Who built this?" -> energy_var;
LOOM VAR [energy_var > 1000] {
    ETCH "Verified Founder" @15;
}
```

### 3. The `LOCK` Operation
Binds VSA vectors and stores the result in `deep2.bin`.
```sigil
LOCK "SylorLabs" :: "Founder";
```

### 4. Energy Weights with `@`
Weights are specified with `@` followed by 0-15.
```sigil
ETCH "Identity" @15; // Max energy
VOID "Hallucination"; // Zero energy (erasure)
```

### 5. Mood-Gated `LOOM`
Execute logic based on the engine's internal mood state.
```sigil
LOOM MOOD [acceleration] {
    ETCH "Fast Response" @12;
}
```

---

## Part III: Full Example Script (V2.1)

```sigil
// ghost_identity.sgl
// Establish core identity for Ghost Engine V21

BIND "fluent.bin";
BIND "deep2.bin" AS deep2;

LET threshold = 500;

// Interrogate existing state
TEST "SylorLabs" -> current_energy;

LOOM VAR [current_energy < threshold] {
    ETCH "SylorLabs" @15;
    LOCK "SylorLabs" :: "Founder";
}

ETCH "Ghost Engine" @15;

// Erasure of legacy associations
VOID "Requires GPU";
VOID "Cloud AI";

SCAN "Ghost Engine"; // Diagnosis

LOOM MOOD [cruise] {
    ETCH "Standard Precision" @8;
}
```

Welcome to the era of Deterministic Intelligence.