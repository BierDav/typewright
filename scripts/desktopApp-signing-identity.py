#!/usr/bin/env python3
import hashlib
import plistlib
import re
import subprocess
import sys

with open(sys.argv[1], "rb") as file:
    profile = plistlib.load(file)
certificates = {hashlib.sha1(cert).hexdigest().upper() for cert in profile["DeveloperCertificates"]}
identities = subprocess.check_output(["security", "find-identity", "-v", "-p", "codesigning"], text=True)
selector = sys.argv[2] if len(sys.argv) > 2 else ""
for fingerprint, name in re.findall(r'\b([0-9A-F]{40})\s+"([^"\n]+)"', identities):
    if fingerprint in certificates and (not selector or selector.upper() == fingerprint or selector in name):
        print(fingerprint)
        break
else:
    sys.exit("No installed signing identity matches both the dev provisioning profile and TYPEWRIGHT_SIGN_IDENTITY. Install the profile's certificate and private key, or correct the identity override.")
