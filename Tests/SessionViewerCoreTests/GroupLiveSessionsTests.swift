// GroupLiveSessionsTests.swift — the live sidebar's parent/child grouping.
//
// The relationship is already in the data and was being thrown away. A subagent transcript
// lives at `<project>/<uuid>/subagents/…` and a workflow agent at
// `<project>/<uuid>/subagents/workflows/wf_*/…`, so EVERY one of them shares the parent
// session's `sessionUUID`. Rendered flat, a burst of six "different" live rows was often
// one session and its five workers, each repeating the same project path — which is what
// made the sidebar unreadable.
//
// Two properties here are about the LIST NOT MOVING while you read it, and they are the
// reason the ordering has tests at all:
//   • a group's mtime/heat is its FRESHEST member, so a parent that has gone quiet while
//     its workers hammer still sorts as one live thing;
//   • children sort by IDENTITY, never by write time. Sorting children by mtime made them
//     swap places on every 2 s poll while you were looking at them.

import Testing
@testable import SessionViewerCore

@Suite("groupLiveSessions — attachment")
struct GroupLiveSessionsAttachmentTests {

    @Test func emptyInputYieldsNoGroups() {
        #expect(groupLiveSessions([]).isEmpty)
    }

    /// The core rule: children attach to the parent that shares their sessionUUID.
    @Test func childrenAttachToTheParentSharingTheirSessionUUID() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "session", mtime: 1_756_000_000),
            session(uuid: uuid, tier: "subagent", agentId: "acat-artist-5a897953c7b59c51", mtime: 1_756_000_010),
            session(uuid: uuid, tier: "workflow_agent", agentId: "a2ebf25d653e7b4cc",
                    mtime: 1_756_000_020, workflowRunId: "wf_8b429bba-965"),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].sessionUUID == uuid)
        #expect(groups[0].parent?.tier == "session")
        #expect(groups[0].children.count == 2)
        #expect(groups[0].children.allSatisfy { $0.tier != "session" })
    }

    /// Only `tier == "session"` is a parent. Both non-session tiers are children, and a
    /// workflow agent must NOT become a second parent just because it arrived first.
    @Test func onlyTheSessionTierBecomesTheParent() {
        let uuid = "9cda6f37-b582-4d73-ae6a-d61ab339cda0"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "workflow_agent", agentId: "aworker-1111111111111111", mtime: 100),
            session(uuid: uuid, tier: "subagent", agentId: "agent-aworker-2222222222222222", mtime: 100),
            session(uuid: uuid, tier: "session", mtime: 100),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].parent != nil)
        #expect(groups[0].children.count == 2)
    }

    /// A parent-less group STILL appears. This is the normal case for a workflow burst: the
    /// session's own transcript has not been written to inside the 5-minute window, but its
    /// workers have. Dropping the group would hide live work entirely.
    @Test func aGroupWithNoLiveParentStillAppears() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "workflow_agent", agentId: "aone-1111111111111111",
                    mtime: 1_756_000_100, workflowRunId: "wf_8b429bba-965"),
            session(uuid: uuid, tier: "workflow_agent", agentId: "atwo-2222222222222222",
                    mtime: 1_756_000_200, workflowRunId: "wf_8b429bba-965"),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].parent == nil)
        #expect(groups[0].children.count == 2)
        #expect(groups[0].mtime == 1_756_000_200, "a parentless group still reports its freshest write")
    }

    /// A session with no workers is a group of one and renders as a plain parent — no
    /// special case at the call site.
    @Test func aLoneSessionIsAGroupOfOne() {
        let groups = groupLiveSessions([
            session(uuid: "cafd5a9d-e3db-492a-a8fd-56db4fb438fa", tier: "session", mtime: 1_756_000_000),
        ])
        #expect(groups.count == 1)
        #expect(groups[0].parent != nil)
        #expect(groups[0].children.isEmpty)
    }

    @Test func differentUUIDsNeverMerge() {
        let groups = groupLiveSessions([
            session(uuid: "aaaaaaaa-0000-0000-0000-000000000000", tier: "session", mtime: 10),
            session(uuid: "bbbbbbbb-0000-0000-0000-000000000000", tier: "session", mtime: 20),
            session(uuid: "aaaaaaaa-0000-0000-0000-000000000000", tier: "subagent",
                    agentId: "agent-akid-1111111111111111", mtime: 30),
        ])
        #expect(groups.count == 2)
        let byUUID = Dictionary(uniqueKeysWithValues: groups.map { ($0.sessionUUID, $0) })
        #expect(byUUID["aaaaaaaa-0000-0000-0000-000000000000"]?.children.count == 1)
        #expect(byUUID["bbbbbbbb-0000-0000-0000-000000000000"]?.children.isEmpty == true)
    }
}

@Suite("groupLiveSessions — a group's mtime is the MAX across parent and children")
struct GroupLiveSessionsMtimeTests {

    /// The load-bearing case: a parent that has gone quiet while its workers hammer is
    /// still an active group. If mtime came from the parent alone, a 27-agent workflow run
    /// would sink to the bottom of the list at the exact moment it was busiest.
    @Test func aChildIsFresherThanAQuietParent() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "session", mtime: 1_756_000_000, age: 240),
            session(uuid: uuid, tier: "workflow_agent", agentId: "abusy-1111111111111111",
                    mtime: 1_756_000_500, age: 3),
            session(uuid: uuid, tier: "workflow_agent", agentId: "aidle-2222222222222222",
                    mtime: 1_756_000_100, age: 200),
        ])
        #expect(groups[0].mtime == 1_756_000_500)
        // Heat follows the same rule — the group's heat is its HOTTEST member.
        #expect(groups[0].heat == .hot, "a group with one hot worker is a hot group")
    }

    /// …and the other direction: a busy parent with quiet workers.
    @Test func aParentCanBeTheFreshestMember() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "session", mtime: 1_756_000_900, age: 2),
            session(uuid: uuid, tier: "subagent", agentId: "agent-aold-1111111111111111",
                    mtime: 1_756_000_100, age: 280),
        ])
        #expect(groups[0].mtime == 1_756_000_900)
        #expect(groups[0].heat == .hot)
    }

    /// An all-quiet group reports its freshest member and reads as cool, not as missing.
    @Test func anAllQuietGroupStillReportsAMaxAndReadsCool() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "session", mtime: 1_756_000_000, age: 290),
            session(uuid: uuid, tier: "subagent", agentId: "agent-aa-1111111111111111",
                    mtime: 1_756_000_050, age: 260),
        ])
        #expect(groups[0].mtime == 1_756_000_050)
        #expect(groups[0].heat == .cool)
    }

    @Test func totalSizeSumsParentAndChildren() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "session", mtime: 10, size: 1_000),
            session(uuid: uuid, tier: "subagent", agentId: "agent-aa-1111111111111111", mtime: 11, size: 2_500),
            session(uuid: uuid, tier: "subagent", agentId: "agent-ab-2222222222222222", mtime: 12, size: 500),
        ])
        #expect(groups[0].totalSize == 4_000)
    }

    /// A parentless group's size and heat must ignore the absent parent rather than
    /// treating it as a zero-byte, infinitely-old member.
    @Test func aParentlessGroupIgnoresTheMissingParentInSizeAndHeat() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "workflow_agent", agentId: "aone-1111111111111111",
                    mtime: 500, size: 3_000, age: 4),
        ])
        #expect(groups[0].totalSize == 3_000)
        #expect(groups[0].heat == .hot)
    }
}

@Suite("groupLiveSessions — ordering that does not move under the cursor")
struct GroupLiveSessionsOrderTests {

    /// Children sort by IDENTITY (agentId, else path), never by write time — sorting them
    /// by mtime made them swap places on every 2 s poll while you were reading them.
    @Test func childrenSortByIdentityNotByWriteTime() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "subagent", agentId: "azz-1111111111111111", mtime: 9_999),
            session(uuid: uuid, tier: "subagent", agentId: "aaa-2222222222222222", mtime: 1),
            session(uuid: uuid, tier: "subagent", agentId: "amm-3333333333333333", mtime: 5_000),
        ])
        #expect(groups[0].children.map(\.agentId) == ["aaa-2222222222222222",
                                                     "amm-3333333333333333",
                                                     "azz-1111111111111111"])
    }

    /// The order must be identical no matter what order the directory walk returned — that
    /// is what "does not move under the cursor" means in practice.
    @Test func childOrderIsIndependentOfInputOrder() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let kids = [
            session(uuid: uuid, tier: "subagent", agentId: "azz-1111111111111111", mtime: 3),
            session(uuid: uuid, tier: "subagent", agentId: "aaa-2222222222222222", mtime: 2),
            session(uuid: uuid, tier: "subagent", agentId: "amm-3333333333333333", mtime: 1),
        ]
        let forward = groupLiveSessions(kids)[0].children.map(\.agentId)
        let reversed = groupLiveSessions(kids.reversed())[0].children.map(\.agentId)
        #expect(forward == reversed)
    }

    /// A child with no agentId falls back to its path as the sort key, so it still has a
    /// stable position rather than an arbitrary one.
    @Test func aChildWithoutAnAgentIdSortsByPath() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "subagent", agentId: nil, mtime: 1, path: "/z/second.jsonl"),
            session(uuid: uuid, tier: "subagent", agentId: nil, mtime: 2, path: "/a/first.jsonl"),
        ])
        #expect(groups[0].children.map(\.path) == ["/a/first.jsonl", "/z/second.jsonl"])
    }

    /// Groups: ACTIVE (hot/warm) before STALE (cool), then by session uuid — a key that
    /// never changes for the life of a session. Deliberately NOT mtime-descending, which
    /// reshuffled the list continuously with a dozen sessions all writing.
    @Test func activeGroupsSortAboveStaleOnesThenByUUID() {
        let groups = groupLiveSessions([
            session(uuid: "dddddddd-0000-0000-0000-000000000000", tier: "session", mtime: 9_999, age: 3),
            session(uuid: "aaaaaaaa-0000-0000-0000-000000000000", tier: "session", mtime: 1, age: 280),
            session(uuid: "cccccccc-0000-0000-0000-000000000000", tier: "session", mtime: 5_000, age: 90),
            session(uuid: "bbbbbbbb-0000-0000-0000-000000000000", tier: "session", mtime: 2, age: 250),
        ])
        #expect(groups.map(\.sessionUUID) == [
            "cccccccc-0000-0000-0000-000000000000",   // warm  (90s)
            "dddddddd-0000-0000-0000-000000000000",   // hot   (3s)  — uuid decides within the bucket
            "aaaaaaaa-0000-0000-0000-000000000000",   // cool
            "bbbbbbbb-0000-0000-0000-000000000000",   // cool
        ])
    }

    /// Restated as the property that matters: the freshest group is NOT automatically
    /// first. That is intentional — recency moved from POSITION (which forces motion) to
    /// APPEARANCE (the heat dot and the printed age), so rows hold still.
    @Test func theFreshestGroupIsNotAutomaticallyFirst() {
        let groups = groupLiveSessions([
            session(uuid: "zzzzzzzz-0000-0000-0000-000000000000", tier: "session", mtime: 9_999, age: 1),
            session(uuid: "aaaaaaaa-0000-0000-0000-000000000000", tier: "session", mtime: 1, age: 100),
        ])
        #expect(groups.map(\.mtime) == [1, 9_999])
        #expect(groups[0].sessionUUID.hasPrefix("aaaa"))
    }

    /// Ordering is a total, deterministic order — the same input always produces the same
    /// list. `stableGroupOrder` also has to be a strict weak ordering or `sorted(by:)` is
    /// undefined behaviour, so equal-bucket + equal-uuid must compare false both ways.
    @Test func theComparatorIsIrreflexiveAndDeterministic() {
        let a = groupLiveSessions([
            session(uuid: "aaaaaaaa-0000-0000-0000-000000000000", tier: "session", mtime: 1, age: 10),
        ])[0]
        #expect(stableGroupOrder(a, a) == false, "a group must not sort before itself")

        // A scrambled but distinct set of uuids (7 and 12 are coprime, so this is a
        // permutation), with heat alternating so both buckets are populated.
        let input = (0..<12).map { i -> LiveSession in
            let n = (7 * i) % 12
            let uuid = (n < 10 ? "0\(n)" : "\(n)") + "-0000-0000-0000-000000000000"
            return session(uuid: uuid, tier: "session", mtime: 1_000 - i,
                           age: i % 2 == 0 ? 5 : 280)
        }
        let first = groupLiveSessions(input).map(\.sessionUUID)
        let second = groupLiveSessions(input.reversed()).map(\.sessionUUID)
        #expect(first == second, "grouping must not depend on Dictionary iteration order")
    }
}

@Suite("groupLiveSessions — the project label")
struct GroupLiveSessionsProjectTests {

    /// The project is carried ONCE per group instead of repeated on every row — the
    /// repetition that made the flat sidebar unreadable (7 of 12 rows all reading
    /// "/workspace/laris-co/neo-oracle").
    @Test func theGroupCarriesTheProjectOnce() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "session", project: "/workspace/laris-co/neo-oracle", mtime: 10),
            session(uuid: uuid, tier: "subagent", agentId: "agent-aa-1111111111111111",
                    project: "/workspace/laris-co/neo-oracle", mtime: 11),
        ])
        #expect(groups[0].project == "/workspace/laris-co/neo-oracle")
    }

    /// Documented consequence of building the group from the FIRST session seen for a uuid:
    /// the label is whichever member the scan reported first. Every member of a group is by
    /// construction under the same project directory, so this cannot mislabel in practice —
    /// it is pinned here so a future change to the scan order is a visible decision.
    @Test func theLabelComesFromTheFirstMemberSeen() {
        let uuid = "cafd5a9d-e3db-492a-a8fd-56db4fb438fa"
        let groups = groupLiveSessions([
            session(uuid: uuid, tier: "subagent", agentId: "agent-aa-1111111111111111",
                    project: "first-seen", mtime: 11),
            session(uuid: uuid, tier: "session", project: "second-seen", mtime: 10),
        ])
        #expect(groups[0].project == "first-seen")
    }
}
