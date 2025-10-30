#!/bin/bash

# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0

# Sequential Integration Test for Video Streaming Demo
# Runs server and client separately instead of in a complex integrated test
# This approach is simpler and more maintainable

set -e

echo "=========================================="
echo "Sequential Video Streaming Integration Test"
echo "=========================================="

# Clean up any previous log files
rm -f streamingserver.log streamingclient.log

# Change to holohub root directory
cd "$(dirname "$0")/../../../../"

echo ""
echo "Step 1: Building applications..."
./holohub build video_streaming_server --language cpp
./holohub build video_streaming_client --language cpp

echo ""
echo "Step 2: Starting streaming server in background..."
# Run server integration test and redirect output to log file
./holohub test video_streaming_server > streamingserver.log 2>&1 &
SERVER_PID=$!
echo "  Server PID: $SERVER_PID"

# Wait for server to fully initialize
echo "  Waiting 10 seconds for server to initialize..."
sleep 10

# Check if server is still running
if ! kill -0 $SERVER_PID 2>/dev/null; then
    echo "✗ ERROR: Server died during startup!"
    echo "Server log:"
    cat streamingserver.log
    exit 1
fi
echo "  ✓ Server is running"

echo ""
echo "Step 3: Starting streaming client in background (replayer mode)..."
# Run client integration test and redirect output to log file
./holohub test video_streaming_client > streamingclient.log 2>&1 &
CLIENT_PID=$!
echo "  Client PID: $CLIENT_PID"

# Let streaming run for 30 seconds
echo "  Letting streaming run for 30 seconds..."
sleep 30

echo ""
echo "Step 4: Shutting down applications..."

# Stop client gracefully
echo "  Stopping client (PID: $CLIENT_PID)..."
kill -TERM $CLIENT_PID 2>/dev/null || true
sleep 2
kill -KILL $CLIENT_PID 2>/dev/null || true

# Stop server gracefully
echo "  Stopping server (PID: $SERVER_PID)..."
kill -TERM $SERVER_PID 2>/dev/null || true
sleep 2
kill -KILL $SERVER_PID 2>/dev/null || true

echo ""
echo "=========================================="
echo "Step 5: Test Results"
echo "=========================================="

# Check server log for key indicators
echo ""
echo "=== Server Log Analysis ==="
if grep -q "Upstream connection established" streamingserver.log; then
    echo "✓ Server: Upstream connection established"
else
    echo "✗ Server: Upstream connection NOT established"
fi

if grep -q "Downstream connection established" streamingserver.log; then
    echo "✓ Server: Downstream connection established"
else
    echo "✗ Server: Downstream connection NOT established"
fi

if grep -q "Processing UNIQUE frame" streamingserver.log; then
    FRAME_COUNT=$(grep -c "Processing UNIQUE frame" streamingserver.log || echo "0")
    echo "✓ Server: Processed $FRAME_COUNT frames"
else
    echo "✗ Server: No frames processed"
fi

# Check client log for key indicators
echo ""
echo "=== Client Log Analysis ==="
if grep -q "STARTING STREAMING CLIENT" streamingclient.log; then
    echo "✓ Client: Streaming client started"
else
    echo "✗ Client: Streaming client did NOT start"
fi

if grep -q "Frame sent successfully" streamingclient.log; then
    SENT_COUNT=$(grep -c "Frame sent successfully" streamingclient.log || echo "0")
    echo "✓ Client: Sent $SENT_COUNT frames"
else
    echo "✗ Client: No frames sent"
fi

echo ""
echo "=========================================="
echo "Step 6: Full Log Files"
echo "=========================================="

echo ""
echo "=== STREAMING SERVER LOG ==="
cat streamingserver.log

echo ""
echo "=== STREAMING CLIENT LOG ==="
cat streamingclient.log

echo ""
echo "=========================================="
echo "Integration test completed!"
echo "=========================================="
