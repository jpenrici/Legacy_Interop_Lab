package LegacyDev::Components;

=head1 NAME

LegacyDev::Components - the manifest: which components the project has

=head1 DESCRIPTION

The one place that knows the components of the project. C<Check> and
C<Pipeline> are generic: they read this list, so adding a component (the
Python bindings, a UI...) means adding one entry here, not editing them.

Each entry is a hash:

  name       short id, used in messages
  title      section title in the dependency report
  builder    path of its builder.pl, relative to the legacy root. Every
             builder honours the same contract: [all|build|test|clean],
             exit 0 = ok, never needs root, finds its tools from the
             environment variable(s) the C<env> sub provides
  depends    names of components that must be built first (build order is
             derived from it, and cycles are rejected)
  tools      what it needs, checked by C<Check>:
               cobol => 1                 a GnuCOBOL and the C compiler it calls
               cc    => { min, label, option, apt }    a GCC >= min (C)
               cxx   => { min, label, option, apt }    a g++ >= min (C++)
               python => { min, label, option, apt }   a Python >= min with venv
               cmake => 'X.Y'             CMake >= X.Y
  requires   source/data files that must exist
  artifacts  what the builder produces: { path, label }, or for a set of files
             { globs => [patterns], label, missing => 'text when absent' }
  run        what "setup.pl run" starts, with the exit codes it may return
             (ok => [..], warn => { code => why }):
               { exe => 'name' }                  a native executable in legacy/bin;
                                                  its libraries are checked to resolve
                                                  inside legacy/lib
               { name => 'x', via => 'builder-test' }   no native executable (the
                                                  Python bindings): the builder's own
                                                  "test" mode, from legacy/bin
  env        sub ($ctx) returning the environment variables its builder reads
             (the toolchain C<Check> found goes through here)

=head1 ADDING A COMPONENT

Copy the closest entry below (C<python> is the model for anything that is not
compiled), write a builder from the common template (same shared helper block,
verified by C<setup.pl check>), and, if it needs a tool nobody checks yet, add a
C<check_*> function for it in C<LegacyDev::Check>. The UI will be one more entry:

  {
      name => 'ui', title => 'Qt UI', builder => 'ui/builder.pl',
      depends => ['python'],                 # reuses bindings/python/.venv
      tools => {},  requires => [ 'ui/builder.pl', 'ui/app.py' ],
      artifacts => [ { path => 'ui/.built', label => 'ui' } ],
      run => [ { name => 'ui_tests', via => 'builder-test', ok => [0], warn => {} } ],
      env => sub { {} },
  },

=cut

use strict;
use warnings;
use Exporter 'import';
use Cwd            qw(abs_path);
use File::Basename qw(dirname);

our @EXPORT_OK = qw(legacy_root dev_dir components component build_order
  data_dirs exit_meaning);

my $DEV  = abs_path( dirname(__FILE__) . '/..' );
my $ROOT = abs_path("$DEV/..");

sub dev_dir     { return $DEV }
sub legacy_root { return $ROOT }

# Directories the tree needs (created when missing).
sub data_dirs {
    return qw(bin lib data/input/cobol data/store/cobol data/backup);
}

# What the exit codes of cobol_app mean (shown when a run fails).
sub exit_meaning {
    return (
        1 => 'cannot open the input CSV',
        2 => 'cannot write the output .dat',
        3 => 'finished, some input lines were rejected',
        4 => 'amount overflow, run aborted',
    );
}

my @COMPONENTS = (

    # --- COBOL ------------------------------------------------------
    {
        name     => 'cobol',
        title    => 'COBOL side',
        builder  => 'cobol/builder.pl',
        depends  => [],
        tools    => { cobol => 1 },
        requires => [
            'cobol/src/ledger.cob', 'cobol/builder.pl',
            'data/input/cobol/cb_data.csv'
        ],
        artifacts => [
            { path => 'bin/cobol_app', label => 'COBOL executable' },
            {
                globs   => [ 'lib/libcob.so.*', 'lib/libgmp.so.*' ],
                label   => 'bundled libs',
                missing => 'libcob/libgmp not in lib/ yet'
            },
        ],
        run => [
            {
                exe  => 'cobol_app',
                ok   => [0],
                warn => { 3 => 'some input lines were rejected' }
            }
        ],
        env => sub {
            my ($ctx) = @_;
            my %env;
            return \%env unless $ctx->{cobol};
            if ( $ctx->{cobol}{home} ) {
                $env{COBOL_HOME} = $ctx->{cobol}{home};
            }
            else { $env{COBC} = $ctx->{cobol}{cobc} }
            $env{COB_CC} = $ctx->{cobol_cc} if $ctx->{cobol_cc};
            return \%env;
        },
    },

    # --- C ----------------------------------------------------------
    {
        name    => 'bridge',
        title   => 'C bridge',
        builder => 'bridge/builder.pl',
        depends => ['cobol'],
        tools   => {
            cc => {
                min    => 14,
                label  => 'bridge compiler',
                option => 'bridge-cc',
                apt    => 'gcc-14'
            },
            cmake => '3.16',
        },
        requires => [
            'bridge/builder.pl',       'bridge/CMakeLists.txt',
            'bridge/include/bridge.h', 'bridge/src/bridge.c',
            'bridge/tests/main.c'
        ],
        artifacts => [
            { path => 'bin/bridge_test',  label => 'bridge test program' },
            { path => 'lib/lib_c_api.so', label => 'bridge library' },
        ],
        run => [ { exe => 'bridge_test', ok => [0], warn => {} } ],
        env =>
          sub { my %e; $e{CC} = $_[0]{cc} if defined $_[0]{cc}; return \%e },
    },

    # --- C++ --------------------------------------------------------
    {
        name    => 'extender',
        title   => 'C++ extender',
        builder => 'extender/builder.pl',
        depends => ['bridge'],
        tools   => {
            cxx => {
                min    => 14,
                label  => 'extender compiler',
                option => 'extender-cxx',
                apt    => 'g++-14'
            },
            cmake => '3.25',
        },
        requires => [
            'extender/builder.pl',
            'extender/CMakeLists.txt',
            'extender/include/extender.h',
            'extender/include/extender.hpp',
            'extender/src/extender.cpp',
            'extender/src/extender_analytics.cpp',
            'extender/src/extender_ffi.cpp',
            'extender/tests/main.cpp'
        ],
        artifacts => [
            { path => 'bin/extender_test', label => 'extender test program' },
            {
                path  => 'lib/lib_cpp_api.so',
                label => 'extender library'
            },
        ],
        run => [ { exe => 'extender_test', ok => [0], warn => {} } ],
        env =>
          sub { my %e; $e{CXX} = $_[0]{cxx} if defined $_[0]{cxx}; return \%e },
    },

    # --- Lua --------------------------------------------------------
    {
        name    => 'lua',
        title   => 'Lua bindings',
        builder => 'bindings/lua/builder.pl',
        depends => ['extender'],
        tools   => {
            cc => {
                min    => 14,
                label  => 'lua compiler',
                option => 'cc',
                apt    => 'gcc-14'
            },
            cmake => '3.25',
            lua   => {
                version => '5.4',
                label   => 'lua',
                option  => 'lua',
                apt     => 'lua lua5.4 liblua5.4-dev'
            },
        },
        requires => [
            'bindings/lua/builder.pl',      'bindings/lua/CMakeLists.txt',
            'bindings/lua/src/binding.lua', 'bindings/lua/src/lua_extender.c',
            'bindings/lua/tests/main.lua'
        ],
        artifacts => [
            {
                path  => 'bin/dist/lua/lua_extender_core.so',
                label => 'lua module'
            },
            {
                globs   => ['bin/dist/lua/binding.lua'],
                label   => 'lua scripts',
                missing => 'bin/dist/lua/binding.lua not built yet'
            },
        ],
        run => [
            {
                name => 'lua_tests',
                via  => 'builder-test',
                ok   => [0],
                warn => {}
            }
        ],
        env => sub {
            my %e;
            $e{CC}  = $_[0]{cc}  if defined $_[0]{cc};
            $e{LUA} = $_[0]{lua} if defined $_[0]{lua};
            return \%e;
        },
    },

    # --- Rust -------------------------------------------------------
    {
        name    => 'rust',
        title   => 'Rust bindings',
        builder => 'bindings/rust/builder.pl',
        depends => ['extender'],
        tools   => {
            rust => {
                version => '1.99.0',
                label   => 'rust',
                option  => 'rust',
                apt     => 'rust-all'
            },
        },
        requires => [
            'bindings/rust/builder.pl', 'bindings/rust/build.rs',
            'bindings/rust/Cargo.toml', 'bindings/rust/src/ffi.rs',
            'bindings/rust/src/lib.rs'
        ],

        #artifacts => [],
        run => [
            {
                name => 'rust_tests',
                via  => 'builder-test',
                ok   => [0],
                warn => {}
            }
        ],
        env => sub {
            my %e;
            $e{RUST} = $_[0]{rust} if defined $_[0]{rust};
            return \%e;
        },
    },

    # --- Free Pascal ------------------------------------------------
    # Not implemented in the setup.
    # Run perl bindings/freepascal/builder.pl directly!

    # --- Python -----------------------------------------------------
    {
        name    => 'python',
        title   => 'Python bindings',
        builder => 'bindings/python/builder.pl',
        depends => ['extender'],
        tools   => {
            python => {
                min    => '3.10',
                label  => 'python',
                option => 'python',
                apt    => 'python3 python3-venv'
            },
        },
        requires => [
            'bindings/python/builder.pl',
            'bindings/python/requirements-qt.txt',
            'bindings/python/src/legacy_ledger/__init__.py',
            'bindings/python/src/legacy_ledger/_abi.py',
            'bindings/python/src/legacy_ledger/models.py',
            'bindings/python/src/legacy_ledger/ledger.py',
            'bindings/python/src/legacy_ledger/qt.py',
            'bindings/python/tests/test_ledger.py',
            'bindings/python/tests/test_qt.py',
            'bindings/python/examples/table_view.py'
        ],
        artifacts => [
            {
                path  => 'bindings/python/.venv/bin/python',
                label => 'python venv'
            },
            {
                globs =>
                  ['bindings/python/.venv/lib/python*/site-packages/PySide6'],
                label   => 'PySide6 (venv)',
                missing =>
                  'not installed (optional: needed by legacy_ledger.qt)'
            },
        ],
        run => [
            {
                name => 'python_tests',
                via  => 'builder-test',
                ok   => [0],
                warn => {}
            }
        ],
        env => sub {
            my %e;
            $e{PYTHON} = $_[0]{python} if defined $_[0]{python};
            return \%e;
        },
    },

    # --- Others ------------------------------------------------------
    # Next: ui (see "ADDING A COMPONENT" above).
);

sub components { return @COMPONENTS }

sub component {
    my ($name) = @_;
    my ($c)    = grep { $_->{name} eq $name } @COMPONENTS;
    return $c;
}

# Components in an order where every one comes after what it depends on.
# Dies on an unknown dependency or a cycle.
sub build_order {
    my ( @order, %state );    # state: 1 = visiting, 2 = done
    my $visit;
    $visit = sub {
        my ($c) = @_;
        return if ( $state{ $c->{name} } // 0 ) == 2;
        die "dependency cycle through component '$c->{name}'\n"
          if ( $state{ $c->{name} } // 0 ) == 1;
        $state{ $c->{name} } = 1;
        for my $dep ( @{ $c->{depends} } ) {
            my $d = component($dep)
              or die "component '$c->{name}' depends on unknown '$dep'\n";
            $visit->($d);
        }
        $state{ $c->{name} } = 2;
        push @order, $c;
    };
    $visit->($_) for @COMPONENTS;
    return @order;
}

1;
