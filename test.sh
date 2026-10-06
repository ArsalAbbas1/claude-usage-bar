#!/bin/bash
# Unit tests for the transcript reader, session model, pace forecast and memory readings. Runs against
# fixtures in /tmp, so it needs no live Claude Code session and touches nothing under ~/.claude.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p build/testsrc
cp Tests/AgentParserTests.swift build/testsrc/main.swift
swiftc -lsqlite3 -o build/agenttest Sources/Agents.swift Sources/Titles.swift Sources/Transcripts.swift Sources/Pace.swift Sources/KeepWarm.swift Sources/Memory.swift build/testsrc/main.swift
build/agenttest
