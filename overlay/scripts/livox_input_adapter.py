#!/usr/bin/env python3
"""Input adapter: Livox Mid-360 (aggregated PointCloud2 + 6-axis IMU) -> LIO-SAM.

LIO-SAM expects what a Velodyne/Ouster driver publishes and shuts down otherwise:
- a dense cloud (no NaN points),
- a uint16 `ring` field per point (the Mid-360's scan lines are in a uint8
  `line` field),
- a per-point `time` field in seconds relative to the scan start (present),
- an IMU with a valid orientation ("please use a 9-axis IMU"); the Mid-360 IMU
  is 6-axis and publishes an all-zero quaternion,
- accelerometer data in m/s^2 (some Livox streams are in units of g).

This node republishes the cloud in that format and the IMU with the
accelerometer in m/s^2. The orientation is estimated downstream by
imu_filter_madgwick from the accelerometer and gyroscope. Header stamps are
passed through unchanged, so LIO-SAM keeps working in the bag's sensor time.
"""
import numpy as np
import rospy
from sensor_msgs.msg import Imu, PointCloud2, PointField

STANDARD_GRAVITY = 9.80665

_NUMPY_TYPE = {
    PointField.INT8: 'i1', PointField.UINT8: 'u1',
    PointField.INT16: '<i2', PointField.UINT16: '<u2',
    PointField.INT32: '<i4', PointField.UINT32: '<u4',
    PointField.FLOAT32: '<f4', PointField.FLOAT64: '<f8',
}

# Layout of LIO-SAM's PointXYZIRT (Velodyne/Livox): x y z intensity ring time.
OUT_FIELDS = [
    PointField('x', 0, PointField.FLOAT32, 1),
    PointField('y', 4, PointField.FLOAT32, 1),
    PointField('z', 8, PointField.FLOAT32, 1),
    PointField('intensity', 12, PointField.FLOAT32, 1),
    PointField('ring', 16, PointField.UINT16, 1),
    PointField('time', 18, PointField.FLOAT32, 1),
]
OUT_DTYPE = np.dtype({
    'names': ['x', 'y', 'z', 'intensity', 'ring', 'time'],
    'formats': ['<f4', '<f4', '<f4', '<f4', '<u2', '<f4'],
    'offsets': [0, 4, 8, 12, 16, 18],
    'itemsize': 22,
})


class LivoxInputAdapter:
    def __init__(self):
        self.ring_field = rospy.get_param('~ring_field', 'line')
        self.acc_scale = None
        self.pub_cloud = rospy.Publisher(rospy.get_param('~cloud_out', '/points_raw'),
                                         PointCloud2, queue_size=10)
        self.pub_imu = rospy.Publisher(rospy.get_param('~imu_out', '/imu/data_raw'),
                                       Imu, queue_size=400)
        rospy.Subscriber(rospy.get_param('~cloud_in', '/livox/pointcloud'),
                         PointCloud2, self.cloud_cb, queue_size=10)
        rospy.Subscriber(rospy.get_param('~imu_in', '/livox/imu'),
                         Imu, self.imu_cb, queue_size=400)

    def cloud_cb(self, msg):
        names = [f.name for f in msg.fields]
        for required in ('x', 'y', 'z', self.ring_field, 'time'):
            if required not in names:
                rospy.logerr_throttle(5, "[adapter] point field '%s' missing; cloud fields: %s"
                                      % (required, names))
                return
        in_dtype = np.dtype({
            'names': names,
            'formats': [_NUMPY_TYPE[f.datatype] for f in msg.fields],
            'offsets': [f.offset for f in msg.fields],
            'itemsize': msg.point_step,
        })
        pts = np.frombuffer(msg.data, dtype=in_dtype, count=msg.width * msg.height)
        pts = pts[np.isfinite(pts['x']) & np.isfinite(pts['y']) & np.isfinite(pts['z'])]

        out = np.zeros(len(pts), dtype=OUT_DTYPE)
        for name in ('x', 'y', 'z', 'time'):
            out[name] = pts[name]
        if 'intensity' in names:
            out['intensity'] = pts['intensity']
        out['ring'] = pts[self.ring_field]

        self.pub_cloud.publish(PointCloud2(
            header=msg.header, height=1, width=len(out), fields=OUT_FIELDS,
            is_bigendian=False, point_step=OUT_DTYPE.itemsize,
            row_step=OUT_DTYPE.itemsize * len(out), data=out.tobytes(), is_dense=True))

    def imu_cb(self, msg):
        a = msg.linear_acceleration
        if self.acc_scale is None:
            norm = (a.x * a.x + a.y * a.y + a.z * a.z) ** 0.5
            # |acc| at the start is ~1 for a stream in g and ~9.8 for m/s^2.
            self.acc_scale = STANDARD_GRAVITY if norm < 3.0 else 1.0
            rospy.loginfo("[adapter] first |acc|=%.3f -> accelerometer scale %.5f"
                          % (norm, self.acc_scale))
        a.x *= self.acc_scale
        a.y *= self.acc_scale
        a.z *= self.acc_scale
        self.pub_imu.publish(msg)


if __name__ == '__main__':
    rospy.init_node('livox_input_adapter')
    LivoxInputAdapter()
    rospy.spin()
