ARG ROS_DISTRO=noetic
FROM ros:${ROS_DISTRO}-ros-base
ENV DEBIAN_FRONTEND=noninteractive

SHELL ["/bin/bash", "-lc"]

RUN apt-get update && apt-get install -y \
    git \
    build-essential \
    cmake \
    python3-pip \
    nlohmann-json3-dev \
    libpcl-dev \
    libopencv-dev \
    ros-${ROS_DISTRO}-pcl-ros \
    ros-${ROS_DISTRO}-cv-bridge \
    ros-${ROS_DISTRO}-gtsam \
    ros-${ROS_DISTRO}-rosbag

RUN pip3 install rosbags
RUN mkdir -p /test_ws/src
COPY src/ /test_ws/src

# Clone LIO-SAM if submodule is empty
RUN if [ ! -f /test_ws/src/LIO-SAM/package.xml ]; then \
      rm -rf /test_ws/src/LIO-SAM && \
      git clone --depth 1 https://github.com/MapsHD/LIO-SAM.git /test_ws/src/LIO-SAM; \
    fi

# Clone LASzip for converter
RUN if [ ! -f /test_ws/src/lio-sam-to-hdmapping/src/3rdparty/LASzip/CMakeLists.txt ]; then \
      mkdir -p /test_ws/src/lio-sam-to-hdmapping/src/3rdparty && \
      rm -rf /test_ws/src/lio-sam-to-hdmapping/src/3rdparty/LASzip && \
      git clone --depth 1 https://github.com/LASzip/LASzip.git /test_ws/src/lio-sam-to-hdmapping/src/3rdparty/LASzip; \
    fi

RUN if [ ! -f /test_ws/src/livox_ros_driver/package.xml ]; then rm -rf /test_ws/src/livox_ros_driver && git clone https://github.com/Livox-SDK/livox_ros_driver.git /test_ws/src/livox_ros_driver; fi
RUN cd /test_ws && \
    source /opt/ros/${ROS_DISTRO}/setup.bash && \
    rosdep update && \
    rosdep install --from-paths src --ignore-src -r -y || true && \
    source /opt/ros/${ROS_DISTRO}/setup.bash && \
    catkin_make
