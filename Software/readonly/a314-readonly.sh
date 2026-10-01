# Installed by a314 setup-readonly.sh to /etc/profile.d
# Shows at login whether the root file system is protected.

case $- in
	*i*)
		if [ "$(findmnt -no FSTYPE /)" = overlay ]; then
			echo "A314: root file system is read-only, changes outside /home are lost at power off."
			echo "      Run 'sudo a314-maint rw' before apt upgrade or network changes."
		else
			echo "A314: MAINTENANCE MODE, root file system is writable."
			echo "      Shut down properly before power off. Run 'sudo a314-maint ro' when done."
		fi
		;;
esac
