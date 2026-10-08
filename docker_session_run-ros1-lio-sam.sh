#!/bin/bash
# Run LIO-SAM on a rosbag (ROS 1 .bag or ROS 2 bag directory), record output
# topics, then convert the recorded bag to an HDMapping session.
#
# LIO-SAM publishes its lidar-rate optimized pose on /lio_sam/mapping/odometry
# and the full deskewed scan, registered in the odom (world) frame, on
# /lio_sam/mapping/cloud_registered_raw, both stamped with the scan's header
# stamp. We record both, plus /clock as a bag time reference: LIO-SAM's own
# clock is left untouched and the converter translates the result into bag
# time if needed.
#
# With ADAPTER=1 (default, Livox Mid-360 input such as the Bunker DVI dataset)
# the bag's LiDAR and IMU go through overlay/scripts/livox_input_adapter.py and
# imu_filter_madgwick first, which provide what LIO-SAM requires: a dense cloud
# with a ring field, accelerometer in m/s^2 and an IMU orientation.

IMAGE_NAME='lio-sam_noetic'
TMUX_SESSION='ros1_LIO-SAM'

DATASET_CONTAINER_PATH='/ros_ws/dataset/input.bag'
CONVERTED_BAG_CONTAINER='/tmp/dataset_ros1.bag'
BAG_OUTPUT_CONTAINER='/ros_ws/recordings'

RECORDED_BAG_NAME="recorded-LIO-SAM.bag"
HDMAPPING_OUT_NAME="output_hdmapping"

# Recorded topics (used by the converter).
ODOM_TOPIC="${ODOM_TOPIC:-/lio_sam/mapping/odometry}"
CLOUD_TOPIC="${CLOUD_TOPIC:-/lio_sam/mapping/cloud_registered_raw}"

# Input topics in the bag. Defaults: Bunker DVI dataset, reg-1.bag-pc.bag
# (Livox Mid-360 as sensor_msgs/PointCloud2 + its 6-axis IMU).
LIDAR_TOPIC="${LIDAR_TOPIC:-/livox/pointcloud}"
IMU_TOPIC="${IMU_TOPIC:-/livox/imu}"

# ADAPTER=1: Livox input adapter + imu_filter_madgwick in front of LIO-SAM.
# ADAPTER=0: the bag already matches LIO-SAM's expectations (dense cloud with
#            ring + time fields, 9-axis IMU in m/s^2); its topics are remapped
#            to the ones in PARAMS_FILE (upstream params.yaml: points_raw,
#            imu_raw).
ADAPTER="${ADAPTER:-1}"
PARAMS_FILE="${PARAMS_FILE:-params_bunker.yaml}"
LIOSAM_CLOUD_TOPIC="${LIOSAM_CLOUD_TOPIC:-/points_raw}"
LIOSAM_IMU_TOPIC="${LIOSAM_IMU_TOPIC:-/imu_raw}"

# RViz on by default — the live view of how LIO-SAM tracks the dataset.
USE_RVIZ="${USE_RVIZ:-1}"

# Force Mesa software rendering by default so RViz renders even when the host
# GPU driver is not exposed to the container (the libGL "nvidia-drm" / amdgpu case).
LIBGL_SW="${LIBGL_SW:-1}"
if [[ "$LIBGL_SW" == "1" ]]; then LIBGL_ENV="1"; else LIBGL_ENV=""; fi

usage() {
  echo "Usage:"
  echo "  $0 <input.bag-or-ros2bag-dir> <output_dir>"
  echo
  echo "If no arguments are provided, a GUI file selector will be used."
  echo
  echo "Environment variables:"
  echo "  LIDAR_TOPIC  - LiDAR PointCloud2 topic inside the bag (default: /livox/pointcloud)"
  echo "  IMU_TOPIC    - IMU topic inside the bag              (default: /livox/imu)"
  echo "  ADAPTER      - 1/0, Livox input adapter + IMU filter (default: 1)"
  echo "  PARAMS_FILE  - LIO-SAM params file in config/        (default: params_bunker.yaml)"
  echo "  ODOM_TOPIC   - LIO-SAM odometry output topic         (default: /lio_sam/mapping/odometry)"
  echo "  CLOUD_TOPIC  - LIO-SAM registered cloud topic        (default: /lio_sam/mapping/cloud_registered_raw)"
  echo "  USE_RVIZ     - 1/0, launch RViz live view            (default: 1)"
  echo "  PLAY_RATE    - rosbag play rate                      (default: 1.0)"
  exit 1
}

echo "=== LIO-SAM rosbag pipeline ==="

if [[ "$1" == "-h" || "$1" == "--help" ]]; then
  usage
fi

if [[ $# -eq 2 ]]; then
  DATASET_HOST_PATH="$1"
  BAG_OUTPUT_HOST="$2"
elif [[ $# -eq 0 ]]; then
  command -v zenity >/dev/null || {
    echo "Error: zenity is not available"
    exit 1
  }
  DATASET_HOST_PATH=$(zenity --file-selection --title="Select BAG file (or ROS 2 bag directory)")
  BAG_OUTPUT_HOST=$(zenity --file-selection --directory --title="Select output directory")
else
  usage
fi

if [[ -z "$DATASET_HOST_PATH" || -z "$BAG_OUTPUT_HOST" ]]; then
  echo "Error: no file or directory selected"
  exit 1
fi

if [[ ! -e "$DATASET_HOST_PATH" ]]; then
  echo "Error: input does not exist: $DATASET_HOST_PATH"
  exit 1
fi

mkdir -p "$BAG_OUTPUT_HOST"

DATASET_HOST_PATH=$(realpath "$DATASET_HOST_PATH")
BAG_OUTPUT_HOST=$(realpath "$BAG_OUTPUT_HOST")

# roslaunch booleans
RVIZ_ARG=false;    [[ "$USE_RVIZ" == "1" ]] && RVIZ_ARG=true
ADAPTER_ARG=false; [[ "$ADAPTER" == "1" ]]  && ADAPTER_ARG=true

echo "Input           : $DATASET_HOST_PATH"
echo "Output dir      : $BAG_OUTPUT_HOST"
echo "LiDAR topic     : $LIDAR_TOPIC"
echo "IMU topic       : $IMU_TOPIC"
echo "Input adapter   : $ADAPTER_ARG"
echo "Params file     : $PARAMS_FILE"
echo "Odom topic      : $ODOM_TOPIC"
echo "Cloud topic     : $CLOUD_TOPIC"

if [[ -d "$DATASET_HOST_PATH" ]]; then
  INPUT_IS_DIR=1
else
  INPUT_IS_DIR=0
fi

xhost +local:docker >/dev/null

# ── Phase 1: run LIO-SAM + record output topics ──────────────────────────────
docker run -it --rm \
  --network host \
  -e DISPLAY=$DISPLAY \
  -e ROS_HOME=/tmp/.ros \
  -e USE_RVIZ="$USE_RVIZ" \
  -e LIBGL_ALWAYS_SOFTWARE="$LIBGL_ENV" \
  -e LIDAR_TOPIC="$LIDAR_TOPIC" \
  -e IMU_TOPIC="$IMU_TOPIC" \
  -e ADAPTER="$ADAPTER" \
  -e LIOSAM_CLOUD_TOPIC="$LIOSAM_CLOUD_TOPIC" \
  -e LIOSAM_IMU_TOPIC="$LIOSAM_IMU_TOPIC" \
  -e ODOM_TOPIC="$ODOM_TOPIC" \
  -e CLOUD_TOPIC="$CLOUD_TOPIC" \
  -e INPUT_IS_DIR="$INPUT_IS_DIR" \
  -e PLAY_RATE="${PLAY_RATE:-1.0}" \
  -u 1000:1000 \
  -v /tmp/.X11-unix:/tmp/.X11-unix \
  -v "$DATASET_HOST_PATH":"$DATASET_CONTAINER_PATH":ro \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c '

    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash

    # ── If input is a ROS 2 bag directory, convert to a ROS 1 bag ──────────
    if [[ "$INPUT_IS_DIR" == "1" ]]; then
      echo "[convert] Converting ROS 2 bag to ROS 1 bag format..."
      rm -f '"$CONVERTED_BAG_CONTAINER"'
      rosbags-convert '"$DATASET_CONTAINER_PATH"' --dst '"$CONVERTED_BAG_CONTAINER"' || {
        echo "[convert] ERROR: rosbags-convert failed"; exit 1; }
      ROS1_BAG="'"$CONVERTED_BAG_CONTAINER"'"
    else
      ROS1_BAG="'"$DATASET_CONTAINER_PATH"'"
    fi

    export ROS1_BAG
    echo "[convert] ROS 1 bag ready at: $ROS1_BAG"
    ls -la $ROS1_BAG

    # ── Preflight: LIO-SAM needs a PointCloud2 LiDAR topic and an IMU topic ─
    # Without them LIO-SAM receives nothing and the run records no output.
    BAG_INFO=$(rosbag info "$ROS1_BAG" 2>/dev/null)
    if ! echo "$BAG_INFO" | grep -qE "[[:space:]]$LIDAR_TOPIC[[:space:]]+[0-9]+ msgs[[:space:]]+: sensor_msgs/PointCloud2" || \
       ! echo "$BAG_INFO" | grep -qE "[[:space:]]$IMU_TOPIC[[:space:]]+[0-9]+ msgs[[:space:]]+: sensor_msgs/Imu"; then
      echo "[preflight] ERROR: LiDAR topic $LIDAR_TOPIC (sensor_msgs/PointCloud2) and/or"
      echo "[preflight]        IMU topic $IMU_TOPIC (sensor_msgs/Imu) not found in the bag."
      echo "[preflight] PointCloud2 and Imu topics in this bag:"
      echo "$BAG_INFO" | grep -E "msgs[[:space:]]+: sensor_msgs/(PointCloud2|Imu)" || echo "  (none)"
      echo "[preflight] For the Bunker DVI dataset use reg-1.bag-pc.bag (LiDAR on /livox/pointcloud),"
      echo "[preflight] or set LIDAR_TOPIC / IMU_TOPIC to the topics of your bag."
      exit 42
    fi
    echo "[preflight] LiDAR topic $LIDAR_TOPIC and IMU topic $IMU_TOPIC found"

    # With the adapter, the launch subscribes to the bag topics directly.
    # Without it, the bag topics are remapped to the ones LIO-SAM reads.
    REMAP_ARGS=""
    if [[ "$ADAPTER" != "1" ]]; then
      [[ "$LIDAR_TOPIC" != "$LIOSAM_CLOUD_TOPIC" ]] && REMAP_ARGS="$REMAP_ARGS $LIDAR_TOPIC:=$LIOSAM_CLOUD_TOPIC"
      [[ "$IMU_TOPIC" != "$LIOSAM_IMU_TOPIC" ]] && REMAP_ARGS="$REMAP_ARGS $IMU_TOPIC:=$LIOSAM_IMU_TOPIC"
    fi
    export REMAP_ARGS
    echo "[play] rosbag remap args: $REMAP_ARGS"

    tmux new-session -d -s '"$TMUX_SESSION"'

    # ---------- PANE 0: roscore ----------
    tmux send-keys -t '"$TMUX_SESSION"' '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[roscore] starting..."
roscore
'\'' C-m

    # ---------- PANE 1: LIO-SAM (+ adapter, IMU filter, RViz) ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 4
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[lio_sam] launching lio_sam_bench.launch (params='"$PARAMS_FILE"', adapter='"$ADAPTER_ARG"', rviz='"$RVIZ_ARG"') ..."
roslaunch lio_sam lio_sam_bench.launch params:='"$PARAMS_FILE"' adapter:='"$ADAPTER_ARG"' cloud_in:='"$LIDAR_TOPIC"' imu_in:='"$IMU_TOPIC"' rviz:='"$RVIZ_ARG"'
'\'' C-m

    # ---------- PANE 2: rosbag record ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 6
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
rm -f '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] start"
rosbag record '"$ODOM_TOPIC"' '"$CLOUD_TOPIC"' /clock -O '"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME"'
echo "[record] exit"
'\'' C-m

    # ---------- PANE 3: rosbag play ----------
    tmux split-window -v -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 10
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[play] start"
rosbag play --clock --rate ${PLAY_RATE:-1.0} $ROS1_BAG $REMAP_ARGS; tmux wait-for -S BAG_DONE;
echo "[play] done"
'\'' C-m

    # ---------- PANE 4: diagnostics ----------
    tmux split-window -h -t '"$TMUX_SESSION"'
    tmux send-keys -t '"$TMUX_SESSION"' '\''sleep 14
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "=== ROS 1 DIAGNOSTICS ==="
echo ""
echo "--- Active topics ---"
rostopic list
echo ""
for t in /points_raw /imu/data '"$ODOM_TOPIC"' '"$CLOUD_TOPIC"'; do
  echo "--- rate of $t ---"
  timeout 5 rostopic hz "$t" 2>&1 | tail -3 &
done
wait
echo ""
echo "[diag] done — you can type ROS 1 commands here, e.g.:"
echo "  rostopic echo '"$ODOM_TOPIC"'"
'\'' C-m

    # ---------- Control window (window 1) ----------
    # This is the window the user attaches to; the 5 noisy panes are on window 0.
    # It waits for the play pane to signal end of playback, then tears the whole
    # session down.
    tmux new-window -t '"$TMUX_SESSION"' -n control '\''
source /opt/ros/noetic/setup.bash
source /ros_ws/devel/setup.bash
echo "[control] waiting for bag playback to finish..."
tmux wait-for BAG_DONE
echo "[control] bag playback finished — shutting down"

# Give LIO-SAM a moment to process remaining queued scans
sleep 3

# Graceful stop: Ctrl+C to each pane
# Pane layout: 0=roscore, 1=lio_sam+rviz, 2=recorder, 3=play, 4=diag
echo "[control] sending Ctrl+C to all panes..."
tmux send-keys -t '"$TMUX_SESSION"':0.2 C-c
sleep 1
tmux send-keys -t '"$TMUX_SESSION"':0.1 C-c
sleep 1
tmux send-keys -t '"$TMUX_SESSION"':0.0 C-c
sleep 3

# Force-kill by process name
echo "[control] force-killing remaining processes..."
pkill -9 lio_sam          2>/dev/null || true
pkill -9 imu_filter_node  2>/dev/null || true
pkill -9 livox_input      2>/dev/null || true
pkill -9 robot_state      2>/dev/null || true
pkill -9 rviz             2>/dev/null || true
pkill -9 rosmaster        2>/dev/null || true
pkill -9 rosout           2>/dev/null || true
sleep 1

echo "[control] terminating tmux"
tmux kill-server
'\''

    tmux attach -t '"$TMUX_SESSION"'
  '

# The preflight check failed: nothing was recorded, and converting would pick
# up a stale recording from an earlier run.
if [[ $? -eq 42 ]]; then
  echo "=== ABORTED: input check failed, no conversion ==="
  exit 1
fi

# ── Phase 2: convert recorded bag to HDMapping session ────────────────────────
echo "=== Converting recorded bag to HDMapping session ==="

docker run -it --rm \
  --network host \
  -e ROS_HOME=/tmp/.ros \
  -u 1000:1000 \
  -v "$BAG_OUTPUT_HOST":"$BAG_OUTPUT_CONTAINER" \
  "$IMAGE_NAME" \
  /bin/bash -c "
    set -e
    source /opt/ros/noetic/setup.bash
    source /ros_ws/devel/setup.bash
    rosrun lio-sam-to-hdmapping listener \
      \"$BAG_OUTPUT_CONTAINER/$RECORDED_BAG_NAME\" \
      \"$BAG_OUTPUT_CONTAINER/$HDMAPPING_OUT_NAME-LIO-SAM\" \
      \"$ODOM_TOPIC\" \
      \"$CLOUD_TOPIC\"
  "

echo "=== DONE ==="
