# App Review Notes

PodBridge transfers music files selected by the user in the iPhone Files app
to a physical click-wheel iPod. It does not require an account, subscription,
or purchase, and it does not distribute music files.

## Hardware required

- iPhone running iOS 15 or later with hardware that exposes the iPod in Files
- iPod Classic 160 GB (late 2009 / 7th generation)
- Lightning-to-USB adapter and the iPod cable

This is the only hardware profile tested for this release. Other profiles are
shown as experimental and are not required for review.

## Review steps

1. Connect and unlock the iPhone and iPod, then open PodBridge.
2. Tap **Connect your iPod** and choose the iPod root folder in Files.
3. Select **iPod Classic 160 GB (late 2009 / 7th generation)** if prompted.
4. Tap **Add Music** and choose a folder containing one supported audio file.
5. Review the detected songs, tap **Add**, and approve the backup confirmation.
6. Keep both devices connected until the transfer completes, disconnect the iPod,
   and open Music on the iPod to verify the track.

Artwork lookup is optional. It queries MusicBrainz and the Cover Art Archive
only when the user requests it. The transfer itself works without network
access.
