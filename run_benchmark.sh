#!/bin/bash

# run_benchmark.sh - Reusable benchmark runner for LIO-SAM (ROS1)
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_NAME="${1:-}"
INPUT_BAG_FILE="${2:-}"

if [ -z "$CONFIG_NAME" ] || [ -z "$INPUT_BAG_FILE" ]; then
    echo "Usage: $0 <config_name> <input_ros1_bag_file>"
    exit 1
fi

CONFIG_FILE="${SCRIPT_DIR}/configs/${CONFIG_NAME}.env"
if [ ! -f "$CONFIG_FILE" ]; then echo "Error: Config not found: $CONFIG_FILE"; exit 1; fi

INPUT_BAG_FILE="$(realpath -m "$INPUT_BAG_FILE")"
if [ ! -f "$INPUT_BAG_FILE" ]; then echo "Error: Bag not found: $INPUT_BAG_FILE"; exit 1; fi

set -a; source "$CONFIG_FILE"; set +a

INPUT_BAG_DIR="$(dirname "$INPUT_BAG_FILE")"
INPUT_BAG_NAME="$(basename "$INPUT_BAG_FILE")"
EXP_DIR="$(realpath "$(dirname "$INPUT_BAG_DIR")")"
OUTPUT_DIR_ABS="${EXP_DIR}/results/${OUTPUT_DIR}"

echo "=========================================="
echo "Running LIO-SAM benchmark (ROS1)"
echo "Input bag: $INPUT_BAG_FILE"
echo "Output: $OUTPUT_DIR_ABS"
echo "=========================================="

mkdir -p "$OUTPUT_DIR_ABS"

IMAGE="${LIOSAM_IMAGE:-ghcr.io/mapshd/liosam2hdmapping:latest}"

docker run --rm -t \
    -u $(id -u):$(id -g) \
    -e HOME=/tmp -e ROS_HOME=/tmp/.ros \
    -v "${INPUT_BAG_DIR}:/data:ro" \
    -v "${EXP_DIR}:/exp:rw" \
    "${IMAGE}" \
    bash -lc "
      set -e
      mkdir -p /tmp/.ros
      source /opt/ros/noetic/setup.bash
      if [ -f /test_ws/devel/setup.bash ]; then source /test_ws/devel/setup.bash; fi

      BAG=\"/data/${INPUT_BAG_NAME}\"
      OUT_DIR=\"/exp/results/${OUTPUT_DIR}\"
      REC_BAG=\"\${OUT_DIR}/recorded.bag\"

      mkdir -p \"\${OUT_DIR}\"; rm -rf \"\${OUT_DIR}/hdmapping\"

      roscore >/tmp/roscore.log 2>&1 &
      ROSCORE_PID=\$!
      cleanup() { set +e; kill \"\${REC_PID:-}\" \"\${LAUNCH_PID:-}\" \"\${ROSCORE_PID:-}\" 2>/dev/null || true; }
      trap cleanup EXIT

      for i in \$(seq 1 50); do rostopic list >/dev/null 2>&1 && break; sleep 0.2; done
      rosparam set use_sim_time true

      roslaunch ${LIOSAM_LAUNCH} >/tmp/liosam.log 2>&1 &
      LAUNCH_PID=\$!

      rosbag record ${RECORD_TOPICS} -O \"\${REC_BAG}\" >/tmp/record.log 2>&1 &
      REC_PID=\$!

      sleep 2
      rosbag play \"\${BAG}\" ${ROSPLAY_ARGS}
      sleep 2

      kill \"\${REC_PID}\" 2>/dev/null || true; wait \"\${REC_PID}\" 2>/dev/null || true
      kill \"\${LAUNCH_PID}\" 2>/dev/null || true; wait \"\${LAUNCH_PID}\" 2>/dev/null || true

      mkdir -p \"\${OUT_DIR}/hdmapping\"
      rosrun lio-sam-to-hdmapping listener \"\${REC_BAG}\" \"\${OUT_DIR}/hdmapping\"
    "

echo "Benchmark completed! Results: ${OUTPUT_DIR_ABS}"

