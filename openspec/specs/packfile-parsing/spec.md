# Packfile Parsing

## Purpose

Parse a Git packfile into fully-materialized objects, resolving both `OFS_DELTA` and `REF_DELTA` entries (including chained deltas and thin packs) and verifying the pack trailer, so that fetched/cloned history can be materialized into the object database.

## Requirements

### Requirement: Parse packfile header

The parser SHALL validate the packfile header before reading entries. It SHALL reject input whose first four bytes are not the ASCII signature `PACK`, and SHALL reject any version other than 2 or 3. It SHALL read the 32-bit big-endian object count from the header and use it as the number of entries to parse.

#### Scenario: Valid header

- **WHEN** parsing data beginning with `PACK`, a 32-bit version of 2, and a 32-bit object count N
- **THEN** the parser proceeds to read N entries

#### Scenario: Invalid signature

- **WHEN** parsing data whose first four bytes are not `PACK`
- **THEN** the parser throws `GKError.packfileError`

#### Scenario: Unsupported version

- **WHEN** parsing a packfile whose version field is neither 2 nor 3
- **THEN** the parser throws `GKError.packfileError`

### Requirement: Materialize non-delta objects

The parser SHALL read each entry's variable-length type-and-size header, decode the entry's zlib-compressed payload, and produce a `GKRawObject` for the four base types (commit, tree, blob, tag). The materialized object's uncompressed data length SHALL equal the size encoded in the entry header.

#### Scenario: Single base object

- **WHEN** a packfile contains one non-delta entry of a known base type
- **THEN** the parser returns one `GKRawObject` of that type whose data matches the decompressed payload

#### Scenario: Round-trip with the writer

- **WHEN** a set of base objects is encoded with `GKPackfileWriter` and then parsed
- **THEN** the parser returns objects whose OIDs equal the OIDs of the originals

### Requirement: Walk concatenated entries precisely

The parser SHALL determine the exact number of compressed bytes each entry occupies so that the next entry begins at the correct offset. It SHALL record the starting pack offset of every entry for use as an `OFS_DELTA` base.

#### Scenario: Multiple entries

- **WHEN** a packfile contains multiple concatenated entries
- **THEN** the parser materializes every entry without desynchronizing the read offset

### Requirement: Resolve OFS_DELTA entries

The parser SHALL recognize entries of type `OFS_DELTA` (6), decode the negative base offset, locate the base object at `currentEntryOffset - offset` earlier in the pack, decompress the delta payload, and apply it to the base to produce the materialized object. The result SHALL inherit the object type of its base.

#### Scenario: Delta against earlier base

- **WHEN** an `OFS_DELTA` entry references a base that appeared earlier in the same pack
- **THEN** the parser reconstructs the full object by applying the delta to that base

#### Scenario: Type inherited from base

- **WHEN** an `OFS_DELTA` entry is resolved
- **THEN** the materialized object's type equals the base object's type

### Requirement: Resolve REF_DELTA entries

The parser SHALL recognize entries of type `REF_DELTA` (7), read the 20-byte base OID, decompress the delta payload, and apply it to the base. The base SHALL be located inside the pack when present; when absent (thin pack), the parser SHALL request the base from a caller-supplied object-database lookup. If the base cannot be located by either means, the parser SHALL throw `GKError.packfileError`.

#### Scenario: Base present in pack

- **WHEN** a `REF_DELTA` entry references a base OID that is materialized within the same pack
- **THEN** the parser reconstructs the full object by applying the delta to that base

#### Scenario: Thin-pack base resolved via lookup

- **WHEN** a `REF_DELTA` entry references a base OID not present in the pack
- **AND** the caller-supplied lookup returns the base object for that OID
- **THEN** the parser reconstructs the full object using the looked-up base

#### Scenario: Unresolvable base

- **WHEN** a `REF_DELTA` base OID is neither in the pack nor returned by the lookup
- **THEN** the parser throws `GKError.packfileError`

### Requirement: Resolve chained deltas

The parser SHALL resolve deltas whose base is itself a delta, materializing intermediate bases as needed so that the final object is fully reconstructed regardless of entry ordering.

#### Scenario: Delta on delta

- **WHEN** a delta entry's base is another delta entry
- **THEN** the parser fully resolves the chain and returns the final reconstructed object

### Requirement: Apply delta instructions

The delta engine SHALL decode the base-size and result-size varints and process copy and insert instructions. A copy instruction (high bit set) SHALL copy a run of bytes from the base at a decoded offset and length; an insert instruction (high bit clear) SHALL append the next literal bytes from the delta stream. The reconstructed output length SHALL equal the decoded result size.

#### Scenario: Copy and insert

- **WHEN** a delta contains copy instructions referencing the base and insert instructions with literal data
- **THEN** the reconstructed object equals the expected result and its length equals the decoded result size

### Requirement: Verify pack trailer

The parser SHALL verify the trailing 20-byte SHA-1 checksum computed over all preceding pack bytes and SHALL throw `GKError.packfileError` when it does not match.

#### Scenario: Valid trailer

- **WHEN** a packfile's trailing 20 bytes equal the SHA-1 of all preceding bytes
- **THEN** the parser completes successfully

#### Scenario: Corrupted trailer

- **WHEN** a packfile's trailing checksum does not match the computed SHA-1
- **THEN** the parser throws `GKError.packfileError`

### Requirement: Materialize objects into the repository

`unpackPackData(_:)` SHALL parse the supplied pack data using the parser, supplying the repository's object database as the thin-pack base lookup, and SHALL write every materialized `GKRawObject` to the object database.

#### Scenario: Fetch materializes objects

- **WHEN** pack data returned from a fetch is passed to `unpackPackData(_:)`
- **THEN** every object the pack encodes, including delta-encoded objects, is written to the object database
