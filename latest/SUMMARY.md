# Run 1 — failure — 2ef4e84eac8ec465cc354465ad97078d82b80bb6
## resolve.log
## test-iphone.log
1090:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:22:33: error: call to main actor-isolated static method 'plan(items:existing:kind:accountID:)' in a synchronous nonisolated context
1100:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:31:33: error: call to main actor-isolated static method 'plan(items:existing:kind:accountID:)' in a synchronous nonisolated context
1110:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:38:33: error: call to main actor-isolated static method 'plan(items:existing:kind:accountID:)' in a synchronous nonisolated context
1120:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:44:33: error: call to main actor-isolated static method 'snapshotName(_:date:)' in a synchronous nonisolated context
1130:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:116:34: error: call to main actor-isolated static method 'needsCopy(source:target:)' in a synchronous nonisolated context
1131:        XCTAssertTrue(SyncEngine.needsCopy(source: src, target: nil))
1136:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:117:35: error: call to main actor-isolated static method 'needsCopy(source:target:)' in a synchronous nonisolated context
1137:        XCTAssertFalse(SyncEngine.needsCopy(source: src, target: src))
1142:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:120:34: error: call to main actor-isolated static method 'needsCopy(source:target:)' in a synchronous nonisolated context
1143:        XCTAssertTrue(SyncEngine.needsCopy(source: src, target: other))
1148:/Users/runner/work/iCloud-Make/iCloud-Make/iCloudIPATests/EngineTests.swift:123:35: error: call to main actor-isolated static method 'needsCopy(source:target:)' in a synchronous nonisolated context
1149:        XCTAssertFalse(SyncEngine.needsCopy(source: noHash, target: src), "falls back to size")
1180:** TEST FAILED **
## xcodegen.log
