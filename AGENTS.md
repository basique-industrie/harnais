# Local app upgrades

After each successful Harnais upgrade, build and package the app, then quit the
running Harnais app and relaunch the newly built bundle. Verify that the new
process is running. The user has authorized this restart as part of each upgrade;
do not leave it as a manual step or ask for confirmation again.

For development, use `dist/Harnais Dev.app` and bundle identifier
`com.jean.harnais.dev`. Quit that specific app gracefully before relaunching it.
