# End-to-end test with an Android client

This test puts an Android emulator on the LAN of an AP. The emulator gets its
addresses from the AP, like a phone on the Wi-Fi. Then the test pings the
lab targets from the emulator. This shows how Android handles the network of
the environment (RA, DHCP, CLAT, NAT64, DNS64).

The Android node works with each environment that sets `ANDROID_BRIDGE` in
`env.conf` (`ffmuc`: `as-ap1-lan`, `ffbs`: `fb-ap1-lan`).

## Requirements

- An x86_64 Linux host with KVM (`/dev/kvm`). The emulator does not run on
  ARM hosts or without KVM.
- The lab of the environment runs (`./lab.sh -e ENV deploy`).
- About 6 GB disk space for the Android SDK.

## Get the Android SDK

You must download the SDK yourself and accept the Android SDK licenses:

```sh
android/fetch-sdk.sh                  # API 35, image "default" (AOSP)
ANDROID_API=30 android/fetch-sdk.sh   # another API level
```

The script runs the SDK tools in a container and puts the SDK into
`android/sdk/` (git ignores it). Set `ANDROID_SDK` to use another
directory. Use the image tag `default` or `google_apis`: `adb root` does not
work with `google_apis_playstore`.

## Run

```sh
./lab.sh -e ffmuc android up      # build the image, start the emulator
./lab.sh -e ffmuc android test    # results in results/android-tests.txt
./lab.sh -e ffmuc android down
```

Set `ANDROID_API` (and `ANDROID_TAG`) for `up` to the image that you
downloaded. For a shell in the emulator:

```sh
sudo docker exec -it clab-android-e2e-android /sdk/platform-tools/adb shell
```

## How it works

| Part | Function |
| --- | --- |
| `android/android.clab.yml` | The node `android`, linked to the bridge `ANDROID_BRIDGE`. |
| `android/entrypoint.sh` | Makes the AVD, starts the relay and the emulator, makes the guest ready. |
| `android/relay.py` | Connects the network socket of the emulator to the interface `lan`. |
| `android/guest/firewall.sh` | Drops new inbound TCP and UDP in the guest. |
| `android/guest/wifi-socket.sh` | API 31 and later: Wi-Fi is the lab link. Stops the DHCP client of the emulator. |
| `android/guest/net-socket.sh` | API 30 and earlier: bridges the emulator link to Wi-Fi. |
| `android/test.sh` | The tests in `ANDROID_TARGETS`. |

Safety:

- The node has no management network (`network-mode: none`). The guest
  can reach only the lab.
- The relay sends no frames before the guest firewall is set.
- adb runs only in the container. It has no port on the host.

## Tests

`ANDROID_TARGETS` in `env.conf` sets the tests:

| Test | Meaning |
| --- | --- |
| `4:ADDR` | Ping ADDR over IPv4. |
| `6:ADDR` | Ping ADDR over IPv6. |
| `dns:NAME` | Ping NAME. The DNS of the lab must resolve it. |

The default is `4:203.0.113.42 6:2001:db8:cafe::1`. The `ffmuc` environment
also tests NAT64 (`64:ff9b::cb00:712a`) and DNS64 (`internet.lab`).
