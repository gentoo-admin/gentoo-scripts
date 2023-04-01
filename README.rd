Gentoo scripts, which were developed and used in prod for many years.

Before first use, run the command:

  while read -r f; do sed -i 's/SSID-HERE/REAL-SSID-NAME/g' "$f"; done < <(find ~/gentoo-scripts -name '*.sh')

to set the real SSID name.

Scripts without the shebang are not actual scripts, but set of commands to be run separately based on condition.

