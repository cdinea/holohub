# SPDX-FileCopyrightText: Copyright (c) 2025 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
# SPDX-License-Identifier: Apache-2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

cmake_minimum_required(VERSION 3.20)
project(video_streaming LANGUAGES CXX)

# Download the endoscopy sample data (required for testing and replayer mode)
# This must happen BEFORE we add subdirectories so the data is available everywhere
if(HOLOHUB_DOWNLOAD_DATASETS)
  include(holoscan_download_data)
  holoscan_download_data(endoscopy
    URL nvidia/clara-holoscan/holoscan_endoscopy_sample_data:20230222
    DOWNLOAD_NAME holoscan_endoscopy_sample_data_20230222.zip
    DOWNLOAD_DIR ${HOLOHUB_DATA_DIR}
    GENERATE_GXF_ENTITIES
    GXF_ENTITIES_HEIGHT 480
    GXF_ENTITIES_WIDTH 854
    GXF_ENTITIES_CHANNELS 3
    GXF_ENTITIES_FRAMERATE 30
    ALL
  )
endif()

# Build client and server applications using add_subdirectory
# These are children of the video_streaming application
# First, register them as holohub applications so the CLI can discover them
add_holohub_application(video_streaming_client DEPENDS
                        OPERATORS video_streaming_client)

add_holohub_application(video_streaming_server DEPENDS
                        OPERATORS video_streaming_server)

# Then build their contents
add_subdirectory(video_streaming_client)
add_subdirectory(video_streaming_server)

# Add integration testing
if(BUILD_TESTING)
  # Add integration test for video streaming demo
  add_test(NAME video_streaming_integration_test_cpp
           COMMAND bash -c "
             echo '=== Integration Test with Log Verification ==='
             echo 'Starting server and client with log capture...'

             # Determine data directory path - use HOLOHUB_DATA_DIR if set at runtime, then check common paths
             find_data_dir() {
               # Try environment variable first (but skip if it's just "/" or empty)
               if [ -n \"\$HOLOHUB_DATA_DIR\" ] && [ \"\$HOLOHUB_DATA_DIR\" != \"/\" ] && [ -d \"\$HOLOHUB_DATA_DIR/endoscopy\" ]; then
                 echo \"\$HOLOHUB_DATA_DIR/endoscopy\"
                 return 0
               fi
               
               # Try /workspace/holohub/data (common in Docker)
               if [ -d \"/workspace/holohub/data/endoscopy\" ]; then
                 echo \"/workspace/holohub/data/endoscopy\"
                 return 0
               fi
               
               # Try relative to current directory
               if [ -d \"./data/endoscopy\" ]; then
                 echo \"./data/endoscopy\"
                 return 0
               fi
               
               # Try build directory
               if [ -d \"data/endoscopy\" ]; then
                 echo \"data/endoscopy\"
                 return 0
               fi
               
               # Try parent directory data
               if [ -d \"../data/endoscopy\" ]; then
                 echo \"../data/endoscopy\"
                 return 0
               fi
               
               # Search for endoscopy directory anywhere under /workspace (last resort)
               local found_path=\$(find /workspace -type d -name \"endoscopy\" -path \"*/data/endoscopy\" 2>/dev/null | head -1)
               if [ -n \"\$found_path\" ]; then
                 echo \"\$found_path\"
                 return 0
               fi
               
               return 1
             }
             
             DATA_PATH=\$(find_data_dir)
             if [ -z \"\$DATA_PATH\" ]; then
               echo \"✗ Error: Could not find endoscopy data directory. Tried:\"
               echo \"  - \$HOLOHUB_DATA_DIR/endoscopy (from env var)\"
               echo \"  - /workspace/holohub/data/endoscopy\"
               echo \"  - ./data/endoscopy\"
               echo \"  - data/endoscopy\"
               echo \"  - ../data/endoscopy\"
               echo \"  - Recursive search under /workspace\"
               echo \"\"
               echo \"Diagnostic information:\"
               echo \"  Current directory: \$(pwd)\"
               echo \"  HOLOHUB_DATA_DIR: \${HOLOHUB_DATA_DIR:-NOT SET}\"
               echo \"  Workspace contents (if exists): \$(ls -la /workspace/holohub/data 2>/dev/null | head -5 || echo 'N/A')\"
               exit 1
             fi
             
             echo \"Using data directory: \$DATA_PATH\"

             # Initialize variables
             TEST_FAILED=0
             SERVER_CHECKS_PASSED=0
             CLIENT_CHECKS_PASSED=0

             # Create log files
             SERVER_LOG=\$(mktemp /tmp/server_log.XXXXXX)
             CLIENT_LOG=\$(mktemp /tmp/client_log.XXXXXX)

             echo \"Server log: \$SERVER_LOG\"
             echo \"Client log: \$CLIENT_LOG\"

             # Start server in background with log capture
             echo 'Starting streaming server...'
             # Find the streaming_server_demo executable in the build directory
             SERVER_EXEC=\"\"
             # Try known build paths first
             if [ -f \"/workspace/holohub/build-video_streaming/applications/video_streaming/video_streaming_server/cpp/streaming_server_demo\" ]; then
               SERVER_EXEC=\"/workspace/holohub/build-video_streaming/applications/video_streaming/video_streaming_server/cpp/streaming_server_demo\"
             elif [ -f \"applications/video_streaming/video_streaming_server/cpp/streaming_server_demo\" ]; then
               SERVER_EXEC=\"applications/video_streaming/video_streaming_server/cpp/streaming_server_demo\"
             elif [ -f \"${CMAKE_BINARY_DIR}/applications/video_streaming/video_streaming_server/cpp/streaming_server_demo\" ]; then
               SERVER_EXEC=\"${CMAKE_BINARY_DIR}/applications/video_streaming/video_streaming_server/cpp/streaming_server_demo\"
             else
               # Fallback: search for the executable
               SERVER_EXEC=\$(find ${CMAKE_BINARY_DIR} -name \"streaming_server_demo\" -type f 2>/dev/null | grep -v \".cpp\" | head -1)
             fi
             if [ -z \"\$SERVER_EXEC\" ]; then
               echo \"✗ Error: Could not find streaming_server_demo executable\"
               echo \"  Searched in: /workspace/holohub/build-video_streaming/applications/video_streaming/video_streaming_server/cpp/\"
               echo \"  Searched in: applications/video_streaming/video_streaming_server/cpp/\"
               echo \"  CMAKE_BINARY_DIR: ${CMAKE_BINARY_DIR}\"
               exit 1
             fi
             \"\$SERVER_EXEC\" --config applications/video_streaming/video_streaming_server/cpp/streaming_server_demo.yaml > \$SERVER_LOG 2>&1 &
             SERVER_PID=\$!

             # Wait for server to start and check logs
             echo 'Waiting for server to initialize...'
             sleep 10

             # Verify server started correctly
             if ! kill -0 \$SERVER_PID 2>/dev/null; then
               echo '✗ Server process died during startup'
               cat \$SERVER_LOG
               rm -f \$SERVER_LOG \$CLIENT_LOG
               exit 1
             fi

             echo '✓ Server process is running'

             # Start client in background with log capture
             echo 'Starting streaming client...'
             # Find the streaming_client_demo executable in the build directory
             CLIENT_EXEC=\"\"
             # Try known build paths first
             if [ -f \"/workspace/holohub/build-video_streaming/applications/video_streaming/video_streaming_client/cpp/streaming_client_demo\" ]; then
               CLIENT_EXEC=\"/workspace/holohub/build-video_streaming/applications/video_streaming/video_streaming_client/cpp/streaming_client_demo\"
             elif [ -f \"applications/video_streaming/video_streaming_client/cpp/streaming_client_demo\" ]; then
               CLIENT_EXEC=\"applications/video_streaming/video_streaming_client/cpp/streaming_client_demo\"
             elif [ -f \"${CMAKE_BINARY_DIR}/applications/video_streaming/video_streaming_client/cpp/streaming_client_demo\" ]; then
               CLIENT_EXEC=\"${CMAKE_BINARY_DIR}/applications/video_streaming/video_streaming_client/cpp/streaming_client_demo\"
             else
               # Fallback: search for the executable
               CLIENT_EXEC=\$(find ${CMAKE_BINARY_DIR} -name \"streaming_client_demo\" -type f 2>/dev/null | grep -v \".cpp\" | head -1)
             fi
             if [ -z \"\$CLIENT_EXEC\" ]; then
               echo \"✗ Error: Could not find streaming_client_demo executable\"
               echo \"  Searched in: /workspace/holohub/build-video_streaming/applications/video_streaming/video_streaming_client/cpp/\"
               echo \"  Searched in: applications/video_streaming/video_streaming_client/cpp/\"
               echo \"  CMAKE_BINARY_DIR: ${CMAKE_BINARY_DIR}\"
               exit 1
             fi
             \"\$CLIENT_EXEC\" --config applications/video_streaming/video_streaming_client/cpp/streaming_client_demo_replayer.yaml --data \"\$DATA_PATH\" > \$CLIENT_LOG 2>&1 &
             CLIENT_PID=\$!

             # Let streaming run for 30 seconds
             echo 'Letting streaming run for 30 seconds...'
             sleep 30

             # Stop client and server gracefully
             echo 'Stopping client...'
             kill -TERM \$CLIENT_PID 2>/dev/null || true
             sleep 2
             kill -KILL \$CLIENT_PID 2>/dev/null || true

             echo 'Stopping server...'
             kill -TERM \$SERVER_PID 2>/dev/null || true
             sleep 2
             kill -KILL \$SERVER_PID 2>/dev/null || true

             # Now verify logs for actual streaming behavior
             echo ''
             echo '=== Verifying Server Logs ==='

             # Check for client connection
             if grep -q 'Client connected' \$SERVER_LOG; then
               echo '✓ Server: Client connected'
               SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
             else
               echo '✗ Server: No client connection detected'
               TEST_FAILED=1
             fi

             # Check for upstream connection
             if grep -q 'Upstream connection established' \$SERVER_LOG; then
               echo '✓ Server: Upstream connection established'
               SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
             else
               echo '✗ Server: Upstream connection not established'
               TEST_FAILED=1
             fi

             # Check for downstream connection
             if grep -q 'Downstream connection established' \$SERVER_LOG; then
               echo '✓ Server: Downstream connection established'
               SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
             else
               echo '✗ Server: Downstream connection not established'
               TEST_FAILED=1
             fi

            # Check for upstream frame processing (client -> server)
            if grep -q 'Processing UNIQUE frame' \$SERVER_LOG; then
              FRAME_COUNT=\$(grep -c 'Processing UNIQUE frame' \$SERVER_LOG)
              if [ \$FRAME_COUNT -ge 100 ]; then
                echo \"✓ Server: StreamingServerUpstreamOp processed \$FRAME_COUNT unique frames\"
                SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
              else
                echo \"✗ Server: Only \$FRAME_COUNT frames processed (minimum: 100)\"
                TEST_FAILED=1
              fi
            else
              echo '✗ Server: StreamingServerUpstreamOp - No frames processed'
              TEST_FAILED=1
            fi

            # Check for downstream frame transmission (server -> client)
            if grep -q 'DOWNSTREAM: Processing tensor' \$SERVER_LOG; then
              DOWNSTREAM_COUNT=\$(grep -c 'DOWNSTREAM: Processing tensor' \$SERVER_LOG)
              if [ \$DOWNSTREAM_COUNT -ge 100 ]; then
                echo \"✓ Server: StreamingServerDownstreamOp processed \$DOWNSTREAM_COUNT tensors\"
                SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
              else
                echo \"✗ Server: Only \$DOWNSTREAM_COUNT tensors processed (minimum: 100)\"
                TEST_FAILED=1
              fi
            else
              echo '✗ Server: StreamingServerDownstreamOp - No tensors processed'
              TEST_FAILED=1
            fi

            # Check for frame processing statistics
            if grep -q 'Frame Processing Stats' \$SERVER_LOG; then
              echo '✓ Server: Frame processing statistics logged'
              SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
            else
              echo '✗ Server: No frame processing statistics logged'
              TEST_FAILED=1
            fi

             echo ''
             echo '=== Verifying Client Logs ==='

            # Check for successful frame sending
            if grep -q 'Frame sent successfully' \$CLIENT_LOG; then
              SENT_COUNT=\$(grep -c 'Frame sent successfully' \$CLIENT_LOG)
              if [ \$SENT_COUNT -ge 100 ]; then
                echo \"✓ Client: Sent \$SENT_COUNT frames successfully\"
                CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
              else
                echo \"✗ Client: Only \$SENT_COUNT frames sent (minimum: 100)\"
                TEST_FAILED=1
              fi
            else
              echo '✗ Client: No frames sent successfully'
              TEST_FAILED=1
            fi

            # Check for client frame reception (bidirectional verification)
            if grep -q 'CLIENT: Received frame' \$CLIENT_LOG; then
              RECEIVED_COUNT=\$(grep -c 'CLIENT: Received frame' \$CLIENT_LOG)
              if [ \$RECEIVED_COUNT -ge 100 ]; then
                echo \"✓ Client: Received \$RECEIVED_COUNT frames from server\"
                CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
              else
                echo \"✗ Client: Only \$RECEIVED_COUNT frames received (minimum: 100)\"
                TEST_FAILED=1
              fi
            else
              echo '✗ Client: No frames received from server'
              TEST_FAILED=1
            fi

            # Check for frame validation
             if grep -q 'Frame validation passed' \$CLIENT_LOG; then
               echo '✓ Client: Frame validation passed'
               CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
             else
               echo '✗ Client: Frame validation issues'
               TEST_FAILED=1
             fi

             # Check for client streaming start
             if grep -q 'STARTING STREAMING CLIENT' \$CLIENT_LOG; then
               echo '✓ Client: Streaming client started'
               CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
             else
               echo '✗ Client: Streaming client failed to start'
               TEST_FAILED=1
             fi

            echo ''
            echo '=== Test Results Summary ==='
            echo \"Server checks passed: \$SERVER_CHECKS_PASSED\"
            echo \"Client checks passed: \$CLIENT_CHECKS_PASSED\"

            # Determine overall success
            # Use failure flag: ANY check failure causes overall test failure
            if [ \$TEST_FAILED -eq 0 ]; then
               echo '✓ STREAMING VERIFICATION PASSED - All checks passed, frames transmitted!'
             else
               echo '✗ STREAMING VERIFICATION FAILED - One or more checks failed'
               echo ''
               echo '=== Server Log Excerpt ==='
               head -50 \$SERVER_LOG
               echo '...'
               tail -50 \$SERVER_LOG
               echo ''
               echo '=== Client Log Excerpt ==='
               head -50 \$CLIENT_LOG
               echo '...'
               tail -50 \$CLIENT_LOG
             fi

             # Clean up logs
             rm -f \$SERVER_LOG \$CLIENT_LOG

             # Overall result based on failure flag
             if [ \$TEST_FAILED -eq 0 ]; then
               echo '✓ Integration test PASSED'
               exit 0
             else
               echo '✗ Integration test FAILED'
               exit 1
             fi
           "
           WORKING_DIRECTORY ${CMAKE_BINARY_DIR})

  set_tests_properties(video_streaming_integration_test_cpp PROPERTIES
                       TIMEOUT 300
                       PASS_REGULAR_EXPRESSION "Integration test PASSED"
                       FAIL_REGULAR_EXPRESSION "Integration test FAILED")

  # Add Python integration test
  if(HOLOHUB_BUILD_PYTHON)
    # Add integration test for Python video streaming demo
    add_test(NAME video_streaming_integration_test_python
             COMMAND bash -c "
               echo '=== Python Integration Test with Log Verification ==='
               echo 'Starting Python server and client with log capture...'

               # Set up PYTHONPATH to include built Python modules
               export PYTHONPATH=${CMAKE_BINARY_DIR}/python/lib:\$PYTHONPATH
               echo \"PYTHONPATH: \$PYTHONPATH\"

               # Determine data directory path - use HOLOHUB_DATA_DIR if set at runtime, then check common paths
               find_data_dir() {
                 # Try environment variable first
                 if [ -n \"\$HOLOHUB_DATA_DIR\" ] && [ -d \"\$HOLOHUB_DATA_DIR/endoscopy\" ]; then
                   echo \"\$HOLOHUB_DATA_DIR/endoscopy\"
                   return 0
                 fi
                 
                 # Try /workspace/holohub/data (common in Docker)
                 if [ -d \"/workspace/holohub/data/endoscopy\" ]; then
                   echo \"/workspace/holohub/data/endoscopy\"
                   return 0
                 fi
                 
                 # Try relative to current directory
                 if [ -d \"./data/endoscopy\" ]; then
                   echo \"./data/endoscopy\"
                   return 0
                 fi
                 
                 # Try build directory
                 if [ -d \"data/endoscopy\" ]; then
                   echo \"data/endoscopy\"
                   return 0
                 fi
                 
                 # Try parent directory data
                 if [ -d \"../data/endoscopy\" ]; then
                   echo \"../data/endoscopy\"
                   return 0
                 fi
                 
                 # Search for endoscopy directory anywhere under /workspace (last resort)
                 local found_path=\$(find /workspace -type d -name \"endoscopy\" -path \"*/data/endoscopy\" 2>/dev/null | head -1)
                 if [ -n \"\$found_path\" ]; then
                   echo \"\$found_path\"
                   return 0
                 fi
                 
                 return 1
               }
               
               DATA_PATH=\$(find_data_dir)
               if [ -z \"\$DATA_PATH\" ]; then
                 echo \"✗ Error: Could not find endoscopy data directory. Tried:\"
                 echo \"  - \$HOLOHUB_DATA_DIR/endoscopy (from env var)\"
                 echo \"  - /workspace/holohub/data/endoscopy\"
                 echo \"  - ./data/endoscopy\"
                 echo \"  - data/endoscopy\"
                 echo \"  - ../data/endoscopy\"
                 echo \"  - Recursive search under /workspace\"
                 echo \"\"
                 echo \"Diagnostic information:\"
                 echo \"  Current directory: \$(pwd)\"
                 echo \"  HOLOHUB_DATA_DIR: \${HOLOHUB_DATA_DIR:-NOT SET}\"
                 echo \"  Workspace contents (if exists): \$(ls -la /workspace/holohub/data 2>/dev/null | head -5 || echo 'N/A')\"
                 exit 1
               fi
               
               echo \"Using data directory: \$DATA_PATH\"

               # Set environment variables for Python applications
               export HOLOSCAN_INPUT_PATH=\"\$DATA_PATH\"
               export HOLOHUB_DATA_PATH=\"\$DATA_PATH\"

               # Initialize variables
               TEST_FAILED=0
               SERVER_CHECKS_PASSED=0
               CLIENT_CHECKS_PASSED=0

               # Create log files
               SERVER_LOG=\$(mktemp /tmp/server_python_log.XXXXXX)
               CLIENT_LOG=\$(mktemp /tmp/client_python_log.XXXXXX)

               echo \"Python Server log: \$SERVER_LOG\"
               echo \"Python Client log: \$CLIENT_LOG\"

               # Start Python server in background with log capture
               echo 'Starting Python streaming server...'
               # Find and run Python server script - try multiple paths
               SERVER_SCRIPT=\"\"
               if [ -f \"/workspace/holohub/applications/video_streaming/video_streaming_server/python/streaming_server_demo.py\" ]; then
                 SERVER_SCRIPT=\"/workspace/holohub/applications/video_streaming/video_streaming_server/python/streaming_server_demo.py\"
               elif [ -f \"applications/video_streaming/video_streaming_server/python/streaming_server_demo.py\" ]; then
                 SERVER_SCRIPT=\"applications/video_streaming/video_streaming_server/python/streaming_server_demo.py\"
               elif [ -f \"../../../applications/video_streaming/video_streaming_server/python/streaming_server_demo.py\" ]; then
                 SERVER_SCRIPT=\"../../../applications/video_streaming/video_streaming_server/python/streaming_server_demo.py\"
               else
                 echo \"✗ Error: Could not find streaming_server_demo.py\"
                 exit 1
               fi
               python3 \"\$SERVER_SCRIPT\" --width 854 --height 480 > \$SERVER_LOG 2>&1 &
               SERVER_PID=\$!

               # Wait for server to start and check logs
               echo 'Waiting for Python server to initialize...'
               sleep 10

               # Verify server started correctly
               if ! kill -0 \$SERVER_PID 2>/dev/null; then
                 echo '✗ Python Server process died during startup'
                 cat \$SERVER_LOG
                 rm -f \$SERVER_LOG \$CLIENT_LOG
                 exit 1
               fi

               echo '✓ Python Server process is running'

               # Start Python client in background with log capture (using replayer for integration test)
               echo 'Starting Python streaming client...'
               # Find and run Python client script - try multiple paths
               CLIENT_SCRIPT=\"\"
               if [ -f \"/workspace/holohub/applications/video_streaming/video_streaming_client/python/streaming_client_demo.py\" ]; then
                 CLIENT_SCRIPT=\"/workspace/holohub/applications/video_streaming/video_streaming_client/python/streaming_client_demo.py\"
               elif [ -f \"applications/video_streaming/video_streaming_client/python/streaming_client_demo.py\" ]; then
                 CLIENT_SCRIPT=\"applications/video_streaming/video_streaming_client/python/streaming_client_demo.py\"
               elif [ -f \"../../../applications/video_streaming/video_streaming_client/python/streaming_client_demo.py\" ]; then
                 CLIENT_SCRIPT=\"../../../applications/video_streaming/video_streaming_client/python/streaming_client_demo.py\"
               else
                 echo \"✗ Error: Could not find streaming_client_demo.py\"
                 exit 1
               fi
               python3 \"\$CLIENT_SCRIPT\" --source replayer --width 854 --height 480 > \$CLIENT_LOG 2>&1 &
               CLIENT_PID=\$!

               # Let streaming run for 30 seconds
               echo 'Letting Python streaming run for 30 seconds...'
               sleep 30

              # Stop client and server gracefully
              echo 'Stopping Python client...'
              kill -TERM \$CLIENT_PID 2>/dev/null || true
              sleep 2
              kill -KILL \$CLIENT_PID 2>/dev/null || true
              wait \$CLIENT_PID 2>/dev/null || true

              echo 'Stopping Python server...'
              kill -TERM \$SERVER_PID 2>/dev/null || true
              sleep 2
              kill -KILL \$SERVER_PID 2>/dev/null || true
              wait \$SERVER_PID 2>/dev/null || true

               # Now verify logs for actual streaming behavior
               echo ''
               echo '=== Verifying Python Server Logs ==='

               # Check for client connection
               if grep -q 'Client connected' \$SERVER_LOG; then
                 echo '✓ Python Server: Client connected'
                 SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
               else
                 echo '✗ Python Server: No client connection detected'
                 TEST_FAILED=1
               fi

               # Check for upstream connection
               if grep -q 'Upstream connection established' \$SERVER_LOG; then
                 echo '✓ Python Server: Upstream connection established'
                 SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
               else
                 echo '✗ Python Server: Upstream connection not established'
                 TEST_FAILED=1
               fi

               # Check for downstream connection
               if grep -q 'Downstream connection established' \$SERVER_LOG; then
                 echo '✓ Python Server: Downstream connection established'
                 SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
               else
                 echo '✗ Python Server: Downstream connection not established'
                 TEST_FAILED=1
               fi

              # Check for upstream frame processing (client -> server)
              if grep -q 'Processing UNIQUE frame' \$SERVER_LOG; then
                FRAME_COUNT=\$(grep -c 'Processing UNIQUE frame' \$SERVER_LOG)
                if [ \$FRAME_COUNT -ge 100 ]; then
                  echo \"✓ Python Server: StreamingServerUpstreamOp processed \$FRAME_COUNT unique frames\"
                  SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
                else
                  echo \"✗ Python Server: Only \$FRAME_COUNT frames processed (minimum: 100)\"
                  TEST_FAILED=1
                fi
              else
                echo '✗ Python Server: StreamingServerUpstreamOp - No frames processed'
                TEST_FAILED=1
              fi

              # Check for downstream frame transmission (server -> client)
              if grep -q 'DOWNSTREAM: Processing tensor' \$SERVER_LOG; then
                DOWNSTREAM_COUNT=\$(grep -c 'DOWNSTREAM: Processing tensor' \$SERVER_LOG)
                if [ \$DOWNSTREAM_COUNT -ge 100 ]; then
                  echo \"✓ Python Server: StreamingServerDownstreamOp processed \$DOWNSTREAM_COUNT tensors\"
                  SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
                else
                  echo \"✗ Python Server: Only \$DOWNSTREAM_COUNT tensors processed (minimum: 100)\"
                  TEST_FAILED=1
                fi
              else
                echo '✗ Python Server: StreamingServerDownstreamOp - No tensors processed'
                TEST_FAILED=1
              fi

              # Check for frame processing statistics
              if grep -q 'Frame Processing Stats' \$SERVER_LOG; then
                echo '✓ Python Server: Frame processing statistics logged'
                SERVER_CHECKS_PASSED=\$((SERVER_CHECKS_PASSED + 1))
              else
                echo '✗ Python Server: No frame processing statistics logged'
                TEST_FAILED=1
              fi

               echo ''
               echo '=== Verifying Python Client Logs ==='

              # Check for successful frame sending
              if grep -q 'Frame sent successfully' \$CLIENT_LOG; then
                SENT_COUNT=\$(grep -c 'Frame sent successfully' \$CLIENT_LOG)
                if [ \$SENT_COUNT -ge 100 ]; then
                  echo \"✓ Python Client: Sent \$SENT_COUNT frames successfully\"
                  CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
                else
                  echo \"✗ Python Client: Only \$SENT_COUNT frames sent (minimum: 100)\"
                  TEST_FAILED=1
                fi
              else
                echo '✗ Python Client: No frames sent successfully'
                TEST_FAILED=1
              fi

              # Check for client frame reception (bidirectional verification)
              if grep -q 'CLIENT: Received frame' \$CLIENT_LOG; then
                RECEIVED_COUNT=\$(grep -c 'CLIENT: Received frame' \$CLIENT_LOG)
                if [ \$RECEIVED_COUNT -ge 100 ]; then
                  echo \"✓ Python Client: Received \$RECEIVED_COUNT frames from server\"
                  CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
                else
                  echo \"✗ Python Client: Only \$RECEIVED_COUNT frames received (minimum: 100)\"
                  TEST_FAILED=1
                fi
              else
                echo '✗ Python Client: No frames received from server'
                TEST_FAILED=1
              fi

              # Check for frame validation
               if grep -q 'Frame validation passed' \$CLIENT_LOG; then
                 echo '✓ Python Client: Frame validation passed'
                 CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
               else
                 echo '✗ Python Client: Frame validation issues'
                 TEST_FAILED=1
               fi

               # Check for client streaming start
               if grep -qE 'STARTING STREAMING CLIENT|Starting Streaming Client Demo' \$CLIENT_LOG; then
                 echo '✓ Python Client: Streaming client started'
                 CLIENT_CHECKS_PASSED=\$((CLIENT_CHECKS_PASSED + 1))
               else
                 echo '✗ Python Client: Streaming client failed to start'
                 TEST_FAILED=1
               fi

              echo ''
              echo '=== Python Test Results Summary ==='
              echo \"Python Server checks passed: \$SERVER_CHECKS_PASSED\"
              echo \"Python Client checks passed: \$CLIENT_CHECKS_PASSED\"

              # Determine overall success
              # Use failure flag: ANY check failure causes overall test failure
              if [ \$TEST_FAILED -eq 0 ]; then
                 echo '✓ PYTHON STREAMING VERIFICATION PASSED - All checks passed, frames transmitted!'
               else
                 echo '✗ PYTHON STREAMING VERIFICATION FAILED - One or more checks failed'
                 echo ''
                 echo '=== Python Server Log Excerpt ==='
                 head -50 \$SERVER_LOG
                 echo '...'
                 tail -50 \$SERVER_LOG
                 echo ''
                 echo '=== Python Client Log Excerpt ==='
                 head -50 \$CLIENT_LOG
                 echo '...'
                 tail -50 \$CLIENT_LOG
               fi

               # Clean up logs
               rm -f \$SERVER_LOG \$CLIENT_LOG

               # Overall result based on failure flag
               if [ \$TEST_FAILED -eq 0 ]; then
                 echo '✓ Python Integration test PASSED'
                 exit 0
               else
                 echo '✗ Python Integration test FAILED'
                 exit 1
               fi
             "
             WORKING_DIRECTORY ${CMAKE_BINARY_DIR})

   set_tests_properties(video_streaming_integration_test_python PROPERTIES
                        TIMEOUT 300
                        PASS_REGULAR_EXPRESSION "Python Integration test PASSED"
                        FAIL_REGULAR_EXPRESSION "Python Integration test FAILED")
  endif()
endif()
