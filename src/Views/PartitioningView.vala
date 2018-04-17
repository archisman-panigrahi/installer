// -*- Mode: vala; indent-tabs-mode: nil; tab-width: 4 -*-
/*-
 * Copyright (c) 2016-2018 elementary LLC. (https://elementary.io)
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 *
 * Authored by: Michael Aaron Murphy <michael@system76.com>
 */

public class Installer.PartitioningView : AbstractInstallerView  {
    public signal void next_step ();

    private Gtk.Button next_button;
    private Gtk.Button gparted_button;
    private Distinst.Disks disks;
    private Gtk.Box disk_list;
    private Gtk.SizeGroup label_sizer;

    public Gee.ArrayList<Installer.Mount> mounts;
    public Gee.ArrayList<LuksCredentials> luks;

    public static uint64 minimum_disk_size;

    public PartitioningView (uint64 size) {
        minimum_disk_size = size;
        Object (cancellable: true);
    }

    construct {
        mounts = new Gee.ArrayList<Installer.Mount> ();
        luks = new Gee.ArrayList<LuksCredentials> ();
        margin = 12;

        // FIXME: This description string building feels bad for translations, 
        // but I'm not sure what the best way to do it would be.

        var base_description = _("Select which partitions to use across all drives. <b>Selecting \"Format\" will erase ALL data on the selected partition.</b>");

        var required_description = _("You must at least select a <b>Root (/)</b> partition");

        var bootloader = Distinst.bootloader_detect ();
        if (bootloader == Distinst.PartitionTable.GPT) {
            required_description += _(" and a <b>Boot (/boot/efi)</b> partition");
        }

        var recommended_description = _("It is also recommended to select a <b>Swap</b> partition.");

        var full_description = _("%s %s. %s".printf (
            base_description,
            required_description,
            recommended_description
        ));

        var description = new Gtk.Label (full_description);
        description.halign = Gtk.Align.FILL;
        description.max_width_chars = 72;
        description.use_markup = true;
        description.wrap = true;

        disk_list = new Gtk.Box (Gtk.Orientation.VERTICAL, 6);
        disk_list.valign = Gtk.Align.START;
        disk_list.margin = 6;
        disk_list.margin_end = 12;

        var disk_scroller = new Gtk.ScrolledWindow (null, null);
        disk_scroller.hexpand = true;
        disk_scroller.hscrollbar_policy = Gtk.PolicyType.NEVER;
        disk_scroller.add (disk_list);

        content_area.attach (disk_scroller, 0, 0);
        content_area.attach (description, 0, 1);

        load_disks ();

        gparted_button = new Gtk.Button.with_label (_("Modify Partitions…"));
        gparted_button.clicked.connect (() => open_gparted ());
        action_area.add (gparted_button);
        action_area.set_child_secondary (gparted_button, true);
        action_area.set_child_non_homogeneous (gparted_button, true);

        next_button = new Gtk.Button.with_label (_("Erase and Install"));
        next_button.get_style_context ().add_class (Gtk.STYLE_CLASS_DESTRUCTIVE_ACTION);
        next_button.sensitive = false;
        next_button.clicked.connect (() => next_step ());
        action_area.add (next_button);

        show_all ();
    }

    private void load_disks () {
        disks = Distinst.Disks.probe ();
        disks.initialize_volume_groups ();
        label_sizer = new Gtk.SizeGroup (Gtk.SizeGroupMode.BOTH);

        foreach (unowned Distinst.Disk disk in disks.list ()) {
            // Skip root disk or live disk
            if (disk.contains_mount ("/") || disk.contains_mount ("/cdrom")) {
                continue;
            }

            var sector_size = disk.get_sector_size ();
            var size = disk.get_sectors () * sector_size;

            string path = Utils.string_from_utf8 (disk.get_device_path ());

            string model = disk.get_model ();
            string label = (model.length == 0)
                ? disk.get_serial ().replace ("_", " ")
                : model;

            var partitions = new Gee.ArrayList<PartitionBar> ();
            foreach (unowned Distinst.Partition part in disk.list_partitions ()) {
                var partition = new PartitionBar (part, path, sector_size, false, this.set_mount, this.unset_mount, this.mount_is_set, this.decrypt);
                partitions.add (partition);
            }

            var disk_bar = new DiskBar (model, path, size, (owned) partitions);
            label_sizer.add_widget (disk_bar.label);
            disk_list.pack_start (disk_bar);
        }

        foreach (unowned Distinst.LvmDevice disk in disks.list_logical ()) {
            add_logical_disk (disk);
        }

        disk_list.show_all ();
    }

    private void open_gparted () {
        try {
            var process = new GLib.Subprocess.newv ({"gparted"}, GLib.SubprocessFlags.NONE);
            process.wait ();
        } catch (GLib.Error error) {
            stderr.printf ("critical error occurred when executing gparted\n");
        }

        reset_view ();
    }

    private void reset_view () {
        disk_list.get_children ().foreach ((child) => child.destroy ());
        mounts.clear ();
        luks.clear ();
        next_button.sensitive = false;
        load_disks ();
    }

    private void add_logical_disk (Distinst.LvmDevice disk) {
        var sector_size = disk.get_sector_size ();
        var size = disk.get_sectors () * sector_size;

        string path = Utils.string_from_utf8 (disk.get_device_path ());

        string model = disk.get_model ();

        var partitions = new Gee.ArrayList<PartitionBar> ();
        foreach (unowned Distinst.Partition part in disk.list_partitions ()) {
            var partition = new PartitionBar (part, path, sector_size, true, this.set_mount, this.unset_mount, this.mount_is_set, this.decrypt);
            partitions.add (partition);
        }

        var disk_bar = new DiskBar (model, path, size, (owned) partitions);
        label_sizer.add_widget (disk_bar.label);
        disk_list.pack_start (disk_bar);
    }

    private void validate_status () {
        uint8 flags = 0;
        const uint8 ROOT = 1;
        const uint8 BOOT = 2;

        stderr.printf ("DEBUG: Current Layout:\n");
        foreach (Mount m in mounts) {
            stderr.printf (
                "  %s : %s : %s: format? %s\n",
                m.partition_path,
                m.mount_point,
                Distinst.strfilesys (m.filesystem),
                m.should_format () ? "true" : "false"
            );
        }

        foreach (Mount m in mounts) {
            if (m.mount_point == "/" && m.is_valid_root_mount ()) {
                flags |= ROOT;
            } else if (m.mount_point == "/boot/efi" && m.is_valid_boot_mount ()) {
                flags |= BOOT;
            }

            if (flags == ROOT + BOOT) {
                next_button.sensitive = true;
                return;
            }
        }

        next_button.sensitive = false;
    }

    private void decrypt (string device, string pv, string password, DecryptMenu menu) {
        int result = disks.decrypt_partition (device, Distinst.LvmEncryption () {
            physical_volume = pv,
            password = password,
            keydata = null
        });

        switch (result) {
            case 0:
                unowned Distinst.LvmDevice disk = disks.get_logical_device (pv);
                add_logical_disk (disk);
                menu.set_decrypted (pv);
                luks.add (new LuksCredentials (device, pv, password));
                break;
            case 1:
                stderr.printf ("decrypt_partition result is 1\n");
                break;
            case 2:
                stderr.printf ("decrypt: input was not valid UTF-8\n");
                break;
            case 3:
                stderr.printf ("decrypt: either a password or keydata string must be supplied\n");
                break;
            case 4:
                stderr.printf ("decrypt: unable to decrypt partition (possibly invalid password)\n");
                break;
            case 5:
                stderr.printf ("decrypt: the decrypted partition does not have a LVM volume on it\n");
                break;
            case 6:
                stderr.printf ("decrypt: unable to locate LUKS partition at %s\n", device);
                break;
            default:
                stderr.printf ("decrypt: unhandled error value: %d\n", result);
                break;
        }
    }

    private void set_mount (Mount mount) {
        unset_mount_point (mount);
        for (int i = 0; i < mounts.size; i++) {
            if (mounts[i].partition_path == mount.partition_path) {
                mounts[i] = mount;
                validate_status ();
                return;
            }
        }


        validate_status ();
        mounts.add (mount);
        validate_status ();
    }

    private bool mount_is_set (string mount_point) {
        return mounts.any_match ((m) => m.mount_point == mount_point);
    }

    private void unset_mount (string partition) {
        remove_mount_by_partition (partition);
        validate_status ();
    }

    private void remove_mount_by_partition (string partition) {
        for (int i = 0; i < mounts.size; i++) {
            if (mounts[i].partition_path == partition) {
                swap_remove_mount (mounts, i);
                break;
            }
        }
    }

    private void unset_mount_point (Mount src) {
        for (int i = 0; i < mounts.size; i++) {
            var m = mounts[i];
            if (m.mount_point == src.mount_point && m.partition_path != src.partition_path) {
                m.menu.unset ();
                swap_remove_mount (mounts, i);
                break;
            }
        }
    }

    private Mount swap_remove_mount (Gee.ArrayList<Mount> array, int index) {
        array[index] = array[array.size - 1];
        return array.remove_at (array.size - 1);
    }
}

