# tests/test_notify.nim
# Unit and integration test suite for Vine strand lifecycle notifications,
# orchestrator awareness, and project multicast fallback.

import std/[os, osproc, strutils, json, unittest]
import tripwire
import tripwire/plugins/osproc as nfos
import notify, gate, weave, config, strand

suite "Vine Strand Lifecycle Notifications & Multicast Suite":

  test "isNotificationsDisabled detects CLI flag and environment variable":
    delEnv("VINE_NO_NOTIFY")
    check isNotificationsDisabled(false) == false
    check isNotificationsDisabled(true) == true

    putEnv("VINE_NO_NOTIFY", "1")
    check isNotificationsDisabled(false) == true
    check isNotificationsDisabled(true) == true

    putEnv("VINE_NO_NOTIFY", "true")
    check isNotificationsDisabled(false) == true

    delEnv("VINE_NO_NOTIFY")
    check isNotificationsDisabled(false) == false

  test "notifyStrandEvent respects notification suppression":
    let manifest = %*{
      "task_id": "task-test-suppress",
      "project": "vine",
      "orchestrator": "rhizo-test-orch"
    }

    # Case 1: noNotify param = true
    let res1 = notifyStrandEvent(manifest, "STRAND_SUBMITTED", noNotify = true)
    check res1["dispatched"].getBool() == false
    check res1["status"].getStr() == "skipped_disabled"

    # Case 2: VINE_NO_NOTIFY env var
    putEnv("VINE_NO_NOTIFY", "1")
    let res2 = notifyStrandEvent(manifest, "STRAND_SUBMITTED", noNotify = false)
    check res2["dispatched"].getBool() == false
    check res2["status"].getStr() == "skipped_disabled"
    delEnv("VINE_NO_NOTIFY")

  test "isOrchestratorActive accurately reports agent cluster status":
    sandbox:
      allow(nfos.osprocPluginInstance)

    check isOrchestratorActive("") == false
    check isOrchestratorActive("non-existent-agent-xyz-99999") == false

  test "notifyStrandEvent falls back to project multicast when orchestrator is empty or absent":
    sandbox:
      allow(nfos.osprocPluginInstance)

    let manifestNoOrch = %*{
      "task_id": "task-test-multicast",
      "project": "vine-test-sandbox",
      "orchestrator": "non-existent-orch-xyz-12345",
      "author": "worker-2",
      "branch": "strand/task-test-multicast"
    }

    let res = notifyStrandEvent(manifestNoOrch, "STRAND_SUBMITTED", noNotify = false)
    if isRhizoAvailable():
      check res["dispatched"].getBool() == true
      check res["primary_mode"].getStr() == "multicast_fallback"
      check res["primary_target"].getStr() == "@vine-test-sandbox"
      check res["subject"].getStr().contains("STRAND_SUBMITTED: task-test-multicast")

  test "AUDIT_RATIFIED and AUDIT_REJECTED trigger secondary notifications to author":
    sandbox:
      allow(nfos.osprocPluginInstance)

    let manifestAudit = %*{
      "task_id": "task-test-audit-events",
      "project": "vine-test-sandbox",
      "orchestrator": "non-existent-orch",
      "author": "worker-author-offline-sandbox",
      "auditor": "rhizo-auditor-offline-sandbox"
    }

    # AUDIT_RATIFIED
    let resRatified = notifyStrandEvent(manifestAudit, "AUDIT_RATIFIED", noNotify = false)
    if isRhizoAvailable():
      check resRatified["dispatched"].getBool() == true
      check resRatified["subject"].getStr().contains("AUDIT_RATIFIED")
      check resRatified.hasKey("secondary_targets")

    # AUDIT_REJECTED
    let details = %*{"rejection_reason": "Missing negative controls in tests"}
    let resRejected = notifyStrandEvent(manifestAudit, "AUDIT_REJECTED", details, noNotify = false)
    if isRhizoAvailable():
      check resRejected["dispatched"].getBool() == true
      check resRejected["subject"].getStr().contains("AUDIT_REJECTED")
      check resRejected.hasKey("secondary_targets")

  test "STRAND_WOVEN triggers secondary notifications to author and auditor":
    sandbox:
      allow(nfos.osprocPluginInstance)

    let manifestWoven = %*{
      "task_id": "task-test-woven",
      "project": "vine-test-sandbox",
      "orchestrator": "non-existent-orch",
      "author": "worker-author-offline-sandbox",
      "auditor": "rhizo-auditor-offline-sandbox",
      "canonical_repo": "/Users/eek/Development/vine"
    }

    let resWoven = notifyStrandEvent(manifestWoven, "STRAND_WOVEN", noNotify = false)
    if isRhizoAvailable():
      check resWoven["dispatched"].getBool() == true
      check resWoven["subject"].getStr().contains("STRAND_WOVEN")
      check resWoven.hasKey("secondary_targets")
