#==============================================================================
# Encapsulate loading and managing configuration.
#==============================================================================

package CVSLogwatcher::Config;

use v5.36;
use Moo;
with 'MooX::Singleton';

use Carp;
use Path::Tiny;
use List::Util qw(max);
use Mojo::Log;
use Term::ReadKey qw(GetTerminalSize);
use Perl6::Form;

use CVSLogwatcher::Logfile;
use CVSLogwatcher::Target;
use CVSLogwatcher::Repl;
use CVSLogwatcher::Repo::RCS;
use CVSLogwatcher::Repo::Git;

# base directory
has basedir => ( is => 'ro', required => 1, coerce => sub ($b) { path $b } );

# main configuration file
has config_file => (
  is => 'ro', required => 1,
  isa => sub ($cfg) {
    die "Config file $cfg not found" unless $cfg eq '-' || -r $cfg
  },
  coerce => sub ($cfg) { $cfg->isa('Path::Tiny') ? $cfg : path($cfg) },
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

# logfiles
has logfiles => ( is => 'lazy' );

# targets
has targets => ( is => 'lazy' );

# replacements
has repl => ( is => 'lazy' );

# Mojo log instance
has logger => ( is => 'ro', default => sub { Mojo::Log->new });

# configuration repositories
has repos => ( is => 'lazy' );

#-------------------------------------------------------------------------------
# run a perl script from file and return its return value, if the file passed
# in is '-', read the script from stdin
sub _do_script ($file)
{
  my $config;

  # slurp from stdin if told so
  if($file eq '-') {
    local $/;
    $/ = undef;
    binmode(STDIN, ':unix:encoding(UTF-8)');
    $config = <STDIN>;
  }

  # otherwise read specified file
  else {
    $config = $file->slurp_utf8;
  }

  # process the received config
  my $re = eval($config);
  die $@ if $@;
  return $re;
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
# the executing script is in).
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

  if($cfg->{config} && $cfg->{config}{logprefix}) {
    return path $cfg->{config}{logprefix};
  } else {
    return path '/var/log';
  }
}

#------------------------------------------------------------------------------
sub _build_logfiles ($self)
{
  my $cfg = $self->config;
  my %logs;

  for my $logid (keys $cfg->{logfiles}->%*) {
    my @log = $cfg->{logfiles}{$logid}->@*;
    my $logfile = path(shift @log);

    # handle relative filenames
    $logfile = $self->logprefix->child($logfile) if substr($logfile, 0, 1) ne '/';

    # instantiate a logfile
    $logs{$logid} = CVSLogwatcher::Logfile->new(
      id => $logid,
      file => $logfile,
      matches => \@log
    )
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

#-------------------------------------------------------------------------------
# create Repo instances, that represent individual repositories that the
# application shall be storing files into
sub _build_repos ($self)
{
  my @repos;

  foreach my $r ($self->config->{repos}->@*) {
    my $type = delete $r->{type};
    # adapt the base to be an absolute path
    $r->{base} = path($r->{base});
    if($r->{base}->is_relative) {
      $r->{base} = $self->basedir->child($r->{base});
    }
    # instantiate the repositories
    if($type eq 'Git') {
      push(@repos, CVSLogwatcher::Repo::Git->new(%$r));
    } elsif($type eq 'RCS') {
      push(@repos, CVSLogwatcher::Repo::RCS->new(%$r));
    } else {
      die "Unsupported repository type '" . $type . "'";
    }
  }

  return \@repos;
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
# Invoke callback for each configured (logfile, matchid) combination and
# continue until either a) no more (logfile, matchid) combination exist, or b)
# the callback returns true
sub iterate_matches ($self, $cb)
{
  TOP: foreach my $logid (sort keys $self->logfiles->%*) {
    foreach my $matchid ($self->logfiles->{$logid}->matches->@*) {
      last TOP if $cb->($self->logfiles->{$logid}, $matchid);
    }
  }
}

#------------------------------------------------------------------------------
sub find_target ($self, $matchid, $host)
{
  my $cfg = $self->config;

  # remove domain from hostname
  $host =~ s/\..*$//g if $host;

  foreach my $target ($self->targets->@*) {
    # both single matchids and arrays of multiple matchids are supported
    my $target_matchid = $target->config->{'matchid'} // [];
    $target_matchid = [ $target_matchid ] unless ref $target_matchid;
    # "logfile" condition
    next unless grep { $_ eq $matchid } @$target_matchid;
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

#------------------------------------------------------------------------------
# verify that a match id exists, this is only used to validate command-line;
# note, that there might be no log associated to the match id, which is valid
# and functional configuration (such matchid can only be invoked manually)
sub exists_matchid ($self, $matchid)
{
  my $cfg = $self->config;

  foreach my $target ($cfg->{targets}->@*) {
    next unless exists $target->{matchid};
    my @matchids = ref $target->{matchid} ? $target->{matchid}->@* : $target->{matchid};
    return 1 if (grep { $_ eq $matchid } @matchids);
  }

  return 0;
}

#------------------------------------------------------------------------------
# display configure logs and match expressions
sub display_logs ($self)
{
  # get terminal width
  my ($wchar) = GetTerminalSize();
  $wchar = 80 if $wchar < 80;

  # return if there's nothing to output
  unless($self->logfiles->%*) {
    say 'No logs configured';
    return;
  }

  # aux function
  my $_f = sub ($l, $c) { '{' . ($c x ($l-2)) .'}' };

  # make space
  print "\n";

  # get column widths
  my @logfiles = sort keys $self->logfiles->%*;
  my @fields;
  $fields[0] = max (map { length } @logfiles, 5);
  $fields[1] = max (map { length($self->logfiles->{$_}->file) } @logfiles);
  $fields[2] = $wchar - $fields[0] - $fields[1] - 4;

  # create divider betwee headers and content
  my $div = '=' x $fields[0] . '  ' . '=' x $fields[1] . '  ' .
            '=' x $fields[2];

  # create format string
  my $form = $_f->($fields[0], '<') . '  ' . $_f->($fields[1], '<') . '  ' .
    $_f->($fields[2], '[');

  # output heading
  print form $form, 'logid', 'logfile', 'matchid(s)  ';
  print $div, "\n";

  # output the content of the table
  foreach my $logid (@logfiles) {
    print form $form, $logid, $self->logfiles->{$logid}->file,
              join(', ', $self->logfiles->{$logid}->matches->@*);
  }

  print "\n";
}

#------------------------------------------------------------------------------
sub logfiles_with_matchid ($self, $matchid)
{
  my @logfiles;
  foreach my $logid (sort keys $self->logfiles->%*) {
    my $log = $self->logfiles->{$logid};
    foreach my $matchid2 ($log->matches()->@*) {
      push(@logfiles, $log) if $matchid eq $matchid2;
    }
  }
  return @logfiles;
}

1;
