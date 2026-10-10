#!/usr/bin/env perl
# legacy/bindings/lua/builder.pl

=head1 NAME

builder.pl - build and test the Lua 5.4 bindings, C<bin/dist/lua>

=head1 SYNOPSIS

  perl bindings/lua/builder.pl [all|build|test|clean]        (default: all)

  CC=gcc-14 LUA=lua5.4 perl bindings/lua/builder.pl

=head1 DESCRIPTION

Builds, from C<bindings/lua/> into a folder that runs as it is:

  bin/dist/lua/lua_extender_core.so   native Lua module (C) over lib_cpp_api.so
  bin/dist/lua/binding.lua            the high-level API
  bin/dist/lua/main.lua               the smoke test (tests/*)

The module finds C<lib/> through C<$ORIGIN/../../lib>, so the tree can be moved.
The smoke test runs from C<legacy/bin>, like every other test, with the Lua
environment variables discarded (the script sets its own module paths).

Requires C<lib/lib_cpp_api.so> (C<perl extender/builder.pl>), the Lua 5.4
headers (Debian: C<liblua5.4-dev>), CMake 3.25 or newer and B<GCC 14 or newer>.
The tests also need C<bin/cobol_app> and a Lua 5.4 interpreter (C<lua5.4>).

=over 4

=item B<build>  configure and compile the module, copy the scripts

=item B<test>   run bin/dist/lua/main.lua (must be built)

=item B<all>    build, then test

=item B<clean>  remove what this builder put in bin/dist/lua (data is never touched)

=back

=head1 ENVIRONMENT

  CC=gcc-14                 the C compiler (GCC >= 14)
  LUA=lua5.4                the interpreter used by the test (must be Lua 5.4)
  LEGACY_ALLOW_ROOT=1       allow running as root (refused by default)

Compiler flags and library paths inherited from the caller are discarded.

=head1 EXIT STATUS

0 success, 1 failure (message on stderr), 2 usage error.

=cut

use strict;
use warnings;
use Cwd            qw(abs_path);
use File::Basename qw(dirname basename);
use File::Copy     qw(copy);
use File::Path     qw(make_path);
use File::Temp     qw(tempdir);

# ------------------------------------------------------------------ main

sub main {
    my $mode = parse_args(@_);
    require_unprivileged();
    scrub_environment();

    my $ctx = build_context();
    return do_clean($ctx) if $mode eq 'clean';

    check_prerequisites( $ctx, $mode );
    find_toolchain($ctx) if $mode ne 'test';
    do_build($ctx)       if $mode ne 'test';
    do_test($ctx)        if $mode ne 'build';
    return 0;
}

# Mode from the command line: all | build | test | clean.
sub parse_args {
    my @args = @_;
    my $mode = @args ? shift @args : 'all';
    return $mode if $mode =~ /^(?:all|build|test|clean)$/ && !@args;
    print STDERR "usage: builder.pl [all|build|test|clean]\n";
    exit 2;
}

# ----------------------------------------------------------------- modes

# Removes the files this builder put in bin/dist/lua (never other bindings'),
# and the folders only if that left them empty.
sub do_clean {
    my ($ctx) = @_;
    my @ours = (
        $ctx->{module}, $ctx->{script},
        map { "$ctx->{dist}/" . basename($_) } glob("$ctx->{here}/tests/*")
    );
    unlink @ours;
    rmdir $ctx->{dist};
    rmdir "$ctx->{root}/bin/dist";
    print "builder: cleaned\n";
    return 0;
}

sub do_build {
    my ($ctx) = @_;
    cmake_build(
        source  => $ctx->{here},
        prefix  => 'legacy_lua',
        cmake   => $ctx->{cmake},
        defines => { CMAKE_C_COMPILER => $ctx->{cc} },
    );
    print
"builder: built bin/dist/lua (lua_extender_core.so, binding.lua, main.lua)\n";
    return 0;
}

sub do_test {
    my ($ctx) = @_;
    chdir $ctx->{bin} or fail("chdir $ctx->{bin}: $!");    # like any other test
    local %ENV = lua_env();
    return run( $ctx->{lua}, 'dist/lua/main.lua' );
}

# ----------------------------------------------------- component specifics

sub build_context {
    my $here = abs_path( dirname(__FILE__) );
    my $root = abs_path("$here/../..");
    my $dist = "$root/bin/dist/lua";
    return {
        here   => $here,
        root   => $root,
        bin    => "$root/bin",
        dist   => $dist,
        module => "$dist/lua_extender_core.so",
        script => "$dist/binding.lua",
    };
}

# Building needs the extender; testing also needs COBOL, the module and Lua.
sub check_prerequisites {
    my ( $ctx, $mode ) = @_;
    require_artifact( $ctx->{root}, 'lib/lib_cpp_api.so',
        'perl extender/builder.pl' );
    if ( $mode ne 'build' ) {
        require_artifact( $ctx->{root}, 'bin/cobol_app',
            'perl cobol/builder.pl' );
        locate_lua($ctx);
    }
    if ( $mode eq 'test' ) {
        require_artifact(
            $ctx->{root},
            'bin/dist/lua/lua_extender_core.so',
            'perl bindings/lua/builder.pl build'
        );
        return 1;
    }
    return ensure_writable_dirs( $ctx->{bin} );
}

# cmake, and a GCC >= 14 (the Lua headers are looked for by CMake itself).
sub find_toolchain {
    my ($ctx) = @_;
    $ctx->{cmake} = find_in_path('cmake') or fail('cmake not found');

    my @candidates =
      grep { defined && length } ( $ENV{CC}, qw(gcc-15 gcc-14 gcc) );
    my ( $cc, $major ) = pick_compiler( 14, @candidates );
    fail(   'GCC >= 14 not found (tried: '
          . join( ' ', @candidates )
          . '); set CC=/path/to/gcc-14' )
      unless $cc;
    print "builder: using $cc (GCC $major)\n";
    $ctx->{cc} = $cc;
    return 1;
}

# The interpreter must be Lua 5.4, the version the module is compiled against.
sub locate_lua {
    my ($ctx)      = @_;
    my @candidates = grep { defined && length } ( $ENV{LUA}, qw(lua5.4 lua) );
    for my $cmd (@candidates) {
        next unless valid_command($cmd);
        my $path = $cmd =~ m{/} ? $cmd : find_in_path($cmd);
        next unless $path && -x $path;
        my ( $rc, $out ) = capture( $path, '-v' );
        next unless $rc == 0 && $out =~ /^Lua 5\.4\b/;
        $ctx->{lua} = $path;
        return 1;
    }
    fail(   'Lua 5.4 interpreter not found (tried: '
          . join( ' ', @candidates )
          . '); apt install lua5.4 or set LUA=/path/to/lua5.4' );
}

# Lua reads these at start-up (LUA_INIT even runs code): the test must not
# depend on, or be changed by, the caller's.
sub lua_env {
    my %env = %ENV;
    delete @env{
        qw(LUA_INIT LUA_INIT_5_4 LUA_PATH LUA_PATH_5_4 LUA_CPATH LUA_CPATH_5_4)
    };
    return %env;
}

# ---------------------------------------------------------------- shared

# BEGIN shared-builder-helpers
# Identical in every builder (cobol, bridge, extender): `setup.pl check`
# verifies it. Safe by construction: no shell, no root, no inherited flags.

sub fail { print STDERR "builder: @_\n"; exit 1 }

# Runs a command in list form (never through a shell); a failure stops the build.
sub run {
    my @cmd = @_;
    print "builder: @cmd\n";
    system(@cmd) == 0 or fail("failed: @cmd");
    return 1;
}

# Output of a command (stdout and stderr merged) and its exit code. List form.
sub capture {
    my @cmd = @_;
    my $pid = open( my $fh, '-|' ) // fail("cannot fork: $!");
    if ( !$pid ) {
        open( STDERR, '>&', \*STDOUT );
        exec { $cmd[0] } @cmd or exit 127;
    }
    local $/;
    my $out = <$fh>;
    close $fh;
    return ( $? >> 8, $out // '' );
}

# Build outputs must not end up owned by root: a normal user could no longer
# rebuild or clean them. Nothing here ever needs privileges.
sub require_unprivileged {
    return 1 if $> != 0;
    if ( ( $ENV{LEGACY_ALLOW_ROOT} // '' ) eq '1' ) {
        print STDERR
"builder: WARNING running as root (LEGACY_ALLOW_ROOT=1): the files will be owned by root\n";
        return 1;
    }
    fail(   "refusing to run as root: the files would be owned by root.\n"
          . "builder: run as a normal user; no privilege is needed (LEGACY_ALLOW_ROOT=1 overrides, e.g. in a throw-away container)"
    );
}

# Same inputs, same build: nothing inherited from the caller may change it.
sub scrub_environment {
    delete @ENV{
        qw(CFLAGS CXXFLAGS CPPFLAGS LDFLAGS LIBRARY_PATH CPATH C_INCLUDE_PATH
          CPLUS_INCLUDE_PATH LD_LIBRARY_PATH LD_PRELOAD COB_CFLAGS COB_LDFLAGS)
    };
    $ENV{LC_ALL} = 'C';
    umask 022;
    return 1;
}

# A command taken from the environment (CC, CXX, COBC...): plain characters only.
sub valid_command {
    my ($cmd) = @_;
    return defined $cmd && $cmd =~ m{^[A-Za-z0-9_+./-]+$};
}

# Full path of an executable found in PATH, or undef.
sub find_in_path {
    my ($name) = @_;
    for my $dir ( split /:/, $ENV{PATH} // '' ) {
        next                if $dir eq '';
        return "$dir/$name" if -f "$dir/$name" && -x _;
    }
    return;
}

# Major version of a GCC command, or undef.
sub compiler_major {
    my ($cmd) = @_;
    return unless valid_command($cmd);
    my ( $rc, $out ) = capture( $cmd, '-dumpversion' );
    return ( $rc == 0 && $out =~ /^(\d+)/ ) ? $1 : undef;
}

# First candidate that is a GCC of at least $min: ($command, $major), or ().
sub pick_compiler {
    my ( $min, @candidates ) = @_;
    for my $cmd ( grep { defined && length } @candidates ) {
        my $major = compiler_major($cmd) or next;
        return ( $cmd, $major ) if $major >= $min;
    }
    return;
}

# Creates the directories a build writes to and checks they are writable.
sub ensure_writable_dirs {
    my @dirs = @_;
    make_path(@dirs);
    for my $dir (@dirs) {
        -d $dir && -w $dir
          or fail(
            "$dir is not writable by this user; fix the ownership of the tree");
    }
    return 1;
}

# An artifact another component must have produced first.
sub require_artifact {
    my ( $root, $relative, $hint ) = @_;
    -e "$root/$relative" or fail("$relative not found - run: $hint");
    return 1;
}

# Out-of-tree CMake build in a private temporary directory, removed afterwards.
sub cmake_build {
    my (%a)     = @_;    # source, prefix, cmake, defines => { NAME => value }
    my $build   = tempdir( "$a{prefix}_XXXXXX", TMPDIR => 1, CLEANUP => 1 );
    my @defines = map { "-D$_=$a{defines}{$_}" } sort keys %{ $a{defines} };
    run( $a{cmake}, '-S', $a{source}, '-B', $build, @defines,
        '-DCMAKE_BUILD_TYPE=Release' );
    run( $a{cmake}, '--build', $build, '-j' );
    return 1;
}

# Runs ./NAME from legacy/bin, like any user would.
sub run_test_binary {
    my ( $root, $name ) = @_;
    -x "$root/bin/$name" or fail("bin/$name not found - run the build first");
    chdir "$root/bin"    or fail("chdir $root/bin: $!");
    return run("./$name");
}

# END shared-builder-helpers

# ------------------------------------------------------------------ go

exit main(@ARGV) unless caller;
1;
