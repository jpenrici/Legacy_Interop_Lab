#!/usr/bin/perl
use strict;
use warnings;
use File::Path qw(remove_tree);

die "Refusing to run as root (uid 0). Re-run as a regular user.\n"
  if ( $< == 0 || $> == 0 );

print "=== TARGETED CLEANUP UTILITY ===\n\n";

# Define the list of files and directories to delete
my @targets = ( "./bin/legacy_app", "./bin/main_c", "./data/output.dat", );

foreach my $target (@targets) {
    if ( -e $target ) {
        if ( -d $target ) {

            # It's a directory, remove it and its contents recursively
            print "[INFO] Removing directory tree: $target\n";
            my $count = remove_tree( $target, { error => \my $err_list } );

            if (@$err_list) {
                foreach my $diag (@$err_list) {
                    my ( $file, $message ) = %$diag;
                    warn "[ERROR] Failed to remove $file: $message\n";
                }
            }
            else {
                print "[SUCCESS] Directory '$target' removed successfully.\n";
            }
        }
        else {
            # It's a file, unlink it
            print "[INFO] Removing file: $target\n";
            if ( unlink $target ) {
                print "[SUCCESS] File '$target' removed successfully.\n";
            }
            else {
                warn "[ERROR] Could not remove file '$target': $!\n";
            }
        }
    }
    else {
        print "[SKIP] Target not found (already deleted?): $target\n";
    }
}

print "\n=== CLEANUP COMPLETED ===\n";
