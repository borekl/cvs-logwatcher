#==============================================================================
# Encapsulate loading and managing configuration.
#==============================================================================

package CVSLogwatcher::Config;
use Moo;
with 'MooX::Singleton';

use warnings;
use strict;
use v5.10;
use experimental 'signatures', 'postderef';
use Carp;
use Path::Tiny;
use Log::Log4perl qw(get_logger);

use CVSLogwatcher::Logfile;
use CVSLogwatcher::Target;
use CVSLogwatcher::Repl;

# base directory
has basedir => ( is => 'ro', required => 1, coerce => sub ($b) { path $b } );

# main configuration file
has config_file => (
  is => 'ro', required => 1,
  isa => sub ($cfg) {
    die "Config file $cfg not found" unless -r $cfg;
  }
);

# configuration directory, this is automatically filled in from 'config_file'
has _config_dir => (
  is => 'ro', lazy => 1,
  default => sub ($s) { path($s->config_file)->absolute->parent },
);

# parsed configuration
has config => ( is => 'lazy' );

# parsed keyring file
has keyring => ( is => 'lazy');

# scratch directory
has tempdir => ( is => 'lazy' );

# log directory
has logprefix => ( is => 'lazy' );

# repository base dir
has repodir => ( is => 'lazy' );

# logfiles
has logfiles => ( is => 'lazy' );

# targets
has targets => ( is => 'lazy' );

# replacements
has repl => ( is => 'lazy' );

# Log4Perl logger instance
has logger => ( is => 'lazy' );

#-------------------------------------------------------------------------------
# run a perl script and return is return value while handling errors
sub _do_script ($file)
{
  my $result = do(path($file)->absolute);
  unless ($result) {
    croak "couldn't parse $file: $@" if $@;
    croak "couldn't do $file: $!"    unless defined $result;
    croak "couldn't run $file"       unless $result;
  }
  return $result;
}

#------------------------------------------------------------------------------
# load and parse configuration
sub _build_config ($self)
{
  return _do_script($self->config_file);
}

#------------------------------------------------------------------------------
# load and parse keyring
sub _build_keyring ($self)
{
  my $cfg = $self->config;
  my $file = $cfg->{config}{keyring} // undef;

  if($file) {
    $file = $self->_config_dir->child($file);
    die "Cannot find or access keyring file $file" unless -r $file;
    return _do_script($file);
  }

  return {};
}

#------------------------------------------------------------------------------
# get scratch directory; if config.tempdir gives absolute path use that,
# otherwise root the relative path at FindBin's $Bin (that is the directory
# the executing script is in). If config.tempdir
sub _build_tempdir ($self)
{
  my $cfg = $self->config;
  my $d = $self->basedir;

  if(
    exists $cfg->{config}
    && exists $cfg->{config}{tempdir}
    && $cfg->{config}{tempdir}
  ) {
    $d = path $cfg->{config}{tempdir};
    $d = $self->basedir->child($cfg->{config}{tempdir}) unless $d->is_absolute;
  }

  die "Temporary directory '$d' not found" unless $d->is_dir;
  return $d;
}

#------------------------------------------------------------------------------
# handle log directory, ie. the main directory where logs to be observed are
# stored in (usually /var/log)
sub _build_logprefix ($self)
{
  my $cfg = $self->config;

  die 'No config.logprefix defined'
  unless $cfg->{config}{logprefix};

  return path $cfg->{config}{logprefix};
}

#------------------------------------------------------------------------------
# Repository base dir
sub _build_repodir ($self)
{
  my $cfg = $self->config;
  my $dir = path($cfg->{rcs}{rcsrepo} // 'data');

  $dir = $self->basedir->child($dir) unless $dir->is_absolute;

  return $dir;
}

#------------------------------------------------------------------------------
sub _build_logfiles ($self)
{
  my $cfg = $self->config;
  my %logs;

  for my $logid (keys $cfg->{logfiles}->%*) {
    my $log = $cfg->{logfiles}{$logid};
    my $logfile = path $log->{filename};
    # handle relative filenames
    $logfile = $cfg->basedir->child($logfile) if substr($logfile, 0, 1) ne '/';
    # ignore unreadable logfiles
    next if !-r $logfile;
    # instantiate a logfile
    $logs{$logid} = CVSLogwatcher::Logfile->new(
      id => $logid,
      file => $logfile,
      matchre => $log->{match}
    );
  }

  return \%logs;
}

#------------------------------------------------------------------------------
sub _build_targets ($self)
{
  my $cfg = $self->config;

  return [
    map { CVSLogwatcher::Target->new(config => $_) } $cfg->{targets}->@*
  ];
}

#------------------------------------------------------------------------------
# Master Repl instance, initialized with keyring and %D (scratch dir)
sub _build_repl ($self)
{
  CVSLogwatcher::Repl->new(
    $self->keyring->%*,
    '%D' => $self->tempdir->stringify
  );
}

#------------------------------------------------------------------------------
# Log4Perl Logger initialization
sub _build_logger ($self)
{
  # ensure Log4Perl configuration is available
  die "Logging configurartion 'cfg/logging.conf' not found or not readable\n"
  unless -r $self->basedir->child('cfg/logging.conf');

  # initialize
  Log::Log4perl->init_and_watch("cfg/logging.conf", 60);
  my $logger = get_logger('CVS::Main');
  return $logger;
}

#------------------------------------------------------------------------------
# RCS binaries
sub rcs ($self, $p)
{
  my $cfg = $self->config;

  if($p eq 'rcsctl') { return $cfg->{rcs}{rcsctl} // 'rcs' }
  elsif($p eq 'rcsci') { return $cfg->{rcs}{rcsci} // 'ci' }
  elsif($p eq 'rcsco') { return $cfg->{rcs}{rcsco} // 'co' }

  die "Invalid rcs argument '$p'";
}

#------------------------------------------------------------------------------
# Ping configuration
sub ping ($self) { $self->config->{ping} // undef }

#------------------------------------------------------------------------------
# Return true if the user passed as argument is on the ignore list
sub is_ignored_user ($self, $u)
{
  exists $self->config->{ignoreusers}
  && ref $self->config->{ignoreusers}
  && grep { lc eq lc $u } $self->config->{ignoreusers}->@*;
}

#------------------------------------------------------------------------------
# Return true if the host passed as argument is on the ignore list
sub is_ignored_host ($self, $h)
{
  exists $self->config->{ignorehosts}
  && ref $self->config->{ignorehosts}
  && grep { $h =~ /$_/ } $self->config->{ignorehosts}->@*;
}

#------------------------------------------------------------------------------
sub iterate_logfiles ($self, $cb)
{
  foreach my $log (keys $self->logfiles->%*) {
    $cb->($self->logfiles->{$log});
  }
}

#------------------------------------------------------------------------------
sub find_target ($self, $logid, $host)
{
  my $cfg = $self->config;

  # remove domain from hostname
  $host =~ s/\..*$//g if $host;

  foreach my $target ($self->targets->@*) {
    # "logfile" condition
    next if
      exists $target->config->{'logfile'}
      && $target->config->{'logfile'} ne $logid;
    # "hostmatch" condition
    next if $host && !$target->match_hostname($host);
    # no mismatch, target found
    return $target;
  }
}

#------------------------------------------------------------------------------
# Return target instance by id
sub get_target ($self, $id)
{
  my ($target) = grep { $_->id eq $id } $self->targets->@*;
  return $target;
}

#------------------------------------------------------------------------------
# Gets admin group name from hostname. Admin group is decided based on
# regexes define in "groups" top-level config object.
sub admin_group ($self, $host)
{
  my $cfg = $self->config;

  for my $grp (keys $cfg->{'groups'}->%*) {
    for my $re_src ($cfg->{'groups'}{$grp}->@*) {
      my $re = qr/$re_src/i;
      return $grp if $host =~ /$re/;
    }
  }
  return undef;
}

1;
