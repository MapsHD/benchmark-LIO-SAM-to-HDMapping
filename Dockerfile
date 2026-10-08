FROM ubuntu:20.04

SHELL ["/bin/bash", "-c"]
ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=Etc/UTC

# ── Base tools ────────────────────────────────────────────────────────────────
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    gnupg2 \
    lsb-release \
    software-properties-common \
    build-essential \
    cmake \
    git \
    apt-transport-https \
    ca-certificates \
    wget \
    libeigen3-dev \
    libboost-all-dev \
    libpcl-dev \
    libopencv-dev \
    nlohmann-json3-dev \
    tmux \
    python3-pip \
    python3-numpy \
    && rm -rf /var/lib/apt/lists/*

# ── ROS 1 Noetic + LIO-SAM dependencies ──────────────────────────────────────
# ros-noetic-gtsam: the GTSAM the MapsHD/LIO-SAM fork is built against.
# ros-noetic-imu-filter-madgwick: estimates the IMU orientation LIO-SAM
# requires, for 6-axis IMUs such as the Livox Mid-360's.
RUN curl -sSL https://raw.githubusercontent.com/ros/rosdistro/master/ros.key \
    | gpg --dearmor -o /usr/share/keyrings/ros-archive-keyring.gpg && \
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/ros-archive-keyring.gpg] \
    http://packages.ros.org/ros/ubuntu $(lsb_release -cs) main" \
    > /etc/apt/sources.list.d/ros.list && \
    apt-get update && apt-get install -y --no-install-recommends \
    ros-noetic-desktop-full \
    ros-noetic-gtsam \
    ros-noetic-imu-filter-madgwick \
    ros-noetic-pcl-conversions \
    ros-noetic-pcl-ros \
    ros-noetic-cv-bridge \
    ros-noetic-rosbag \
    ros-noetic-rosbag-storage \
    && rm -rf /var/lib/apt/lists/*

# ── rosbags (used to convert ROS 2 bags to ROS 1, if needed) ─────────────────
RUN pip3 install --no-cache-dir "rosbags==0.9.22"

# ── Build catkin workspace (LIO-SAM + converter) ─────────────────────────────
WORKDIR /ros_ws

COPY ./src/LIO-SAM               ./src/LIO-SAM
COPY ./src/lio-sam-to-hdmapping  ./src/lio-sam-to-hdmapping

# Benchmark launch, Bunker DVI params and the Livox input adapter, added into
# the lio_sam package (see overlay/launch/lio_sam_bench.launch).
COPY ./overlay/launch/  ./src/LIO-SAM/launch/
COPY ./overlay/config/  ./src/LIO-SAM/config/
COPY ./overlay/scripts/ ./src/LIO-SAM/scripts/
RUN chmod +x ./src/LIO-SAM/scripts/*.py

# Build LIO-SAM (4 nodes) and the converter. The final guard fails the image
# build loudly if any executable or runtime dependency is missing.
RUN source /opt/ros/noetic/setup.bash && \
    catkin_make -DCMAKE_BUILD_TYPE=Release -j4 && \
    test -f /ros_ws/devel/lib/lio_sam/lio_sam_imuPreintegration && \
    test -f /ros_ws/devel/lib/lio_sam/lio_sam_imageProjection && \
    test -f /ros_ws/devel/lib/lio_sam/lio_sam_featureExtraction && \
    test -f /ros_ws/devel/lib/lio_sam/lio_sam_mapOptmization && \
    test -f /ros_ws/devel/lib/lio-sam-to-hdmapping/listener && \
    test -x /ros_ws/src/LIO-SAM/scripts/livox_input_adapter.py && \
    source /ros_ws/devel/setup.bash && rospack find imu_filter_madgwick >/dev/null && \
    python3 -c "import numpy, rospy" && \
    echo "[build] lio_sam nodes, adapter, imu filter and converter present"

# ── Non-root user ─────────────────────────────────────────────────────────────
ARG UID=1000
ARG GID=1000
RUN groupadd -g $GID ros && \
    useradd -m -u $UID -g $GID -s /bin/bash ros && \
    chown -R $UID:$GID /ros_ws

RUN echo "source /opt/ros/noetic/setup.bash"   >> /root/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /root/.bashrc && \
    echo "source /opt/ros/noetic/setup.bash"   >> /home/ros/.bashrc && \
    echo "source /ros_ws/devel/setup.bash"     >> /home/ros/.bashrc

CMD ["bash"]
