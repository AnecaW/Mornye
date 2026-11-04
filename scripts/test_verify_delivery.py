import unittest
from verify_delivery import android_version_code


class VersionCodeTests(unittest.TestCase):
    def test_pinned_flutter_split_codes(self):
        self.assertEqual(android_version_code("167", {"arm64-v8a"}), "2167")
        self.assertEqual(android_version_code("167", {"armeabi-v7a"}), "1167")
        self.assertEqual(android_version_code("167", {"x86_64"}), "4167")

    def test_universal_code(self):
        self.assertEqual(android_version_code("167", {"arm64-v8a", "armeabi-v7a"}), "167")


if __name__ == "__main__":
    unittest.main()
