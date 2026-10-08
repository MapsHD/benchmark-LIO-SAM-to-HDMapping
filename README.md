## Hint

Please change branch to [Bunker-DVI-Dataset-reg-1](https://github.com/MapsHD/benchmark-LIO-SAM-to-HDMapping/tree/Bunker-DVI-Dataset-reg-1) for quick experiment.

## Example Dataset:

Download the dataset from [Bunker DVI Dataset](https://charleshamesse.github.io/bunker-dvi-dataset/)

# benchmark-LIO-SAM-to-HDMapping

Runs the [LIO-SAM](https://github.com/TixiaoShan/LIO-SAM) LiDAR-inertial
odometry and mapping algorithm on a ROS 1 bag file and converts the output to
an [HDMapping](https://github.com/MapsHD/HDMapping) session.

LIO-SAM (*Tightly-coupled Lidar Inertial Odometry via Smoothing and Mapping*,
T. Shan et al.) fuses LiDAR scan matching with IMU preintegration in a factor
graph (GTSAM) and adds loop closures. The algorithm is used unmodified, from
the [MapsHD/LIO-SAM](https://github.com/MapsHD/LIO-SAM) fork, which only adds
build fixes for ROS Noetic.

## Prerequisites

- Docker
- A ROS 1 bag containing a `sensor_msgs/PointCloud2` LiDAR topic and a
  `sensor_msgs/Imu` topic (ROS 2 bags are automatically converted to ROS 1
  format)

## Step 1 — Clone with submodules

```bash
git clone https://github.com/MapsHD/benchmark-LIO-SAM-to-HDMapping.git --recursive
cd benchmark-LIO-SAM-to-HDMapping
```

## Step 2 — Build the Docker image

```bash
docker build -t lio-sam_noetic .
```

This installs:
- Ubuntu 20.04 + ROS 1 Noetic
- GTSAM (`ros-noetic-gtsam`), PCL, OpenCV, Eigen3
- `imu_filter_madgwick` (IMU orientation for 6-axis IMUs, see below)
- LIO-SAM (compiled from submodule)
- catkin workspace with `lio_sam` and `lio-sam-to-hdmapping`

## Step 3 — Run the pipeline

```bash
chmod +x docker_session_run-ros1-lio-sam.sh
./docker_session_run-ros1-lio-sam.sh /path/to/input.bag /path/to/output/dir
```

Or with no arguments to use a GUI file selector (requires `zenity`).

### Input: what LIO-SAM needs, and the two modes

LIO-SAM only accepts a **dense** point cloud with per-point `ring` and `time`
fields, and a **9-axis IMU** (with orientation) whose accelerometer is in
m/s². It shuts down on anything else. The script supports two cases:

- **`ADAPTER=1` (default): Livox-style input**, e.g. a Livox Mid-360 cloud
  exported as `sensor_msgs/PointCloud2` with a `line` field and the Mid-360's
  6-axis IMU. The input adapter (`overlay/scripts/livox_input_adapter.py`)
  drops invalid points, publishes `line` as `ring`, and scales the
  accelerometer to m/s² if the stream is in units of g.
  [imu_filter_madgwick](http://wiki.ros.org/imu_filter_madgwick) estimates
  the IMU orientation from the accelerometer and gyroscope. LIO-SAM then runs
  with `overlay/config/params_bunker.yaml`: Livox settings from upstream's
  README (`sensor: livox`, `N_SCAN` = scan lines, `Horizon_SCAN` ≥ points per
  line, `edgeFeatureMinValidNum: 1`) with Livox Mid-360 values and
  extrinsics.
- **`ADAPTER=0`: input already in LIO-SAM's format**, e.g. a Velodyne/Ouster
  cloud with `ring` and `time` and a 9-axis IMU. The bag topics are remapped
  to the ones in `PARAMS_FILE` (upstream `params.yaml`: `points_raw`,
  `imu_raw`). Upstream's `params.yaml` carries the LIO-SAM authors' sensor
  model and extrinsics; for another sensor, add your own params file to
  `overlay/config/` and select it with `PARAMS_FILE`.

Example for a Velodyne VLP-16 bag with a 9-axis IMU:

```bash
ADAPTER=0 PARAMS_FILE=params.yaml LIDAR_TOPIC=/velodyne_points IMU_TOPIC=/imu/data \
  ./docker_session_run-ros1-lio-sam.sh /path/to/input.bag /path/to/output/dir
```

Environment variables:

| Variable | Default | Meaning |
|----------|---------|---------|
| `LIDAR_TOPIC` | `/livox/pointcloud` | LiDAR `PointCloud2` topic **in the bag** |
| `IMU_TOPIC` | `/livox/imu` | IMU topic **in the bag** |
| `ADAPTER` | `1` | `1` = Livox input adapter + IMU filter, `0` = bag already in LIO-SAM's format |
| `PARAMS_FILE` | `params_bunker.yaml` | LIO-SAM params file in the `lio_sam` package's `config/` |
| `LIOSAM_CLOUD_TOPIC` | `/points_raw` | with `ADAPTER=0`: cloud topic LIO-SAM reads (from `PARAMS_FILE`) |
| `LIOSAM_IMU_TOPIC` | `/imu_raw` | with `ADAPTER=0`: IMU topic LIO-SAM reads (from `PARAMS_FILE`) |
| `ODOM_TOPIC` | `/lio_sam/mapping/odometry` | recorded odometry |
| `CLOUD_TOPIC` | `/lio_sam/mapping/cloud_registered_raw` | recorded registered cloud |
| `USE_RVIZ` | `1` | RViz live view |
| `LIBGL_SW` | `1` | software OpenGL rendering for RViz (works without a GPU driver in the container) |
| `PLAY_RATE` | `1.0` | rosbag play rate |

**What happens:**

The script opens a Docker container with a tmux session containing five panes on
window 0 and a `control` window (window 1, the attach target):

| Pane | Role |
|------|------|
| 0 | `roscore` |
| 1 | `roslaunch lio_sam lio_sam_bench.launch` — LIO-SAM (+ input adapter, IMU filter and RViz live view) |
| 2 | `rosbag record` of the odometry, the registered cloud and `/clock` |
| 3 | `rosbag play --clock` — plays your input bag |
| 4 | diagnostics — shows active topics and publishing rates |

Before starting, the script checks that the LiDAR and IMU topics exist in the
bag and stops with a list of the bag's topics if they don't. When playback
finishes, the control window stops the recorder, kills all nodes and RViz, and
exits tmux. A second Docker run then converts the recorded bag into the
HDMapping session format.

## Step 4 — Open in HDMapping

Output files appear in `<output_dir>/output_hdmapping-LIO-SAM/`:

```
lio_initial_poses.reg
poses.reg
scan_lio_0.laz
...
session.json
trajectory_lio_0.csv
...
```

Open `session.json` with the
[multi_view_tls_registration_step_2](https://github.com/MapsHD/HDMapping)
application.

## Notes on LIO-SAM

The converter records:

| Topic | Type | Meaning |
|-------|------|---------|
| `/lio_sam/mapping/odometry` | `nav_msgs/Odometry` | the optimized 6-DoF pose in the `odom` (world) frame, after each processed scan |
| `/lio_sam/mapping/cloud_registered_raw` | `sensor_msgs/PointCloud2` | the full deskewed scan, already registered in the `odom` (world) frame |

LIO-SAM updates its map at most every `mappingProcessInterval` (0.15 s), so
the trajectory has fewer poses than the LiDAR has scans.

**Timestamps:** the benchmark does not change LIO-SAM's clock (no
`use_sim_time`). LIO-SAM, the input adapter and the IMU filter all keep the
input header stamps, so the output is in bag time. `/clock` is recorded as a
reference and the converter translates the result into bag time only if it is
not (it reports which case applied).

## Contact

januszbedkowski@gmail.com
