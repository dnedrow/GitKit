# pack-random-access

## ADDED Requirements

### Requirement: Parse pack index files

The system SHALL read Git pack index version 2 (`.idx`) files. It SHALL validate the `\377tOc` magic and version 2, use the 256-entry fanout table to bound the search, and expose a lookup that returns the byte offset of an object within the corresponding `.pack` given its OID. Lookups for OIDs not contained in the index SHALL return no offset rather than an error.

#### Scenario: Resolve a contained OID to an offset

- **WHEN** an OID present in a `.idx` v2 file is looked up
- **THEN** the reader returns that object's byte offset within the `.pack`

#### Scenario: OID not in index

- **WHEN** an OID not present in the index is looked up
- **THEN** the reader returns no offset (and does not throw)

#### Scenario: Invalid index file

- **WHEN** the data does not begin with the `.idx` v2 magic and version
- **THEN** the reader throws `GKError.packfileError`

#### Scenario: Large offsets

- **WHEN** an index entry's 4-byte offset has its high bit set, indicating an entry in the 8-byte large-offset table
- **THEN** the reader resolves the full 64-bit offset from the large-offset table

### Requirement: Read a single object from a pack by offset

The system SHALL materialize a single object located at a given byte offset in a `.pack` without parsing the whole pack. It SHALL decode the entry's type-and-size header and inflate only that entry's zlib stream. For base types (commit, tree, blob, tag) it SHALL return the corresponding `GKRawObject`.

#### Scenario: Read a non-delta object

- **WHEN** a base-type entry at a known offset is read
- **THEN** the reader returns a `GKRawObject` whose type and data match that entry, without inflating other entries

### Requirement: Resolve delta entries during single-object reads

When the entry at the requested offset is a delta, the system SHALL resolve only its base chain. For `OFS_DELTA` it SHALL read the base at `entryOffset - negativeOffset` within the same pack. For `REF_DELTA` it SHALL locate the base by OID — within the same pack via the index, otherwise via a caller-supplied lookup. It SHALL apply the delta to the reconstructed base and inherit the base's object type. If the base cannot be resolved, it SHALL throw `GKError.packfileError`.

#### Scenario: OFS_DELTA single read

- **WHEN** the entry at the requested offset is an `OFS_DELTA`
- **THEN** the reader resolves the base at the referenced earlier offset, applies the delta, and returns the full object with the base's type

#### Scenario: REF_DELTA single read resolved within the pack

- **WHEN** the entry at the requested offset is a `REF_DELTA` whose base OID is present in the same pack's index
- **THEN** the reader resolves the base by offset, applies the delta, and returns the full object

#### Scenario: REF_DELTA base outside the pack

- **WHEN** a `REF_DELTA` base OID is not in the pack and the caller-supplied lookup returns the base
- **THEN** the reader uses the looked-up base to reconstruct the object

#### Scenario: Chained delta single read

- **WHEN** the entry's base is itself a delta
- **THEN** the reader resolves the full chain and returns the final reconstructed object

### Requirement: Index-based object database reads

`GKLooseObjectDatabase` SHALL satisfy reads by first consulting loose storage and then, on a miss, using pack index files under `objects/pack/` to locate and read the single requested object. It SHALL NOT parse an entire pack to satisfy an individual object read when an index is available. `exists(oid:)` SHALL report membership using loose storage and the pack indexes.

#### Scenario: Read a packed object via index

- **WHEN** an object absent from loose storage but present in a pack is read
- **THEN** the database returns it by resolving its offset from the `.idx` and reading only that object and its delta base chain

#### Scenario: Reading one object does not materialize the whole pack

- **WHEN** a single packed object is read from a pack containing many objects
- **THEN** only that object and the objects on its delta base chain are inflated

#### Scenario: Fallback when no index is present

- **WHEN** a `.pack` has no corresponding `.idx`
- **THEN** the database still resolves packed objects (falling back to whole-pack parsing) so reads remain correct

### Requirement: Object read cache

The system SHALL cache materialized objects in memory so repeated reads of the same OID, and shared delta bases, are not re-inflated within a repository instance.

#### Scenario: Repeated read served from cache

- **WHEN** the same OID is read more than once
- **THEN** subsequent reads return the cached object without re-inflating it
