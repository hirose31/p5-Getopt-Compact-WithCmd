package Getopt::Compact::WithCmd;

use strict;
use warnings;
use 5.008_001;
use Getopt::Long qw/GetOptionsFromArray/;
use Carp;
use constant DEFAULT_CONFIG => (no_auto_abbrev => 1, bundling => 1);

our $VERSION = '0.01';

sub new {
    my ($class, %args) = @_;
    my $self = bless {
        cmd         => $args{cmd} || do { require File::Basename; File::Basename::basename($0) },
        name        => $args{name},
        version     => $args{version} || $::VERSION,
        modes       => $args{modes},
        opts        => {},
        usage       => exists $args{usage} && !$args{usage} ? 0 : 1,
        args        => $args{args} || '',
        struct      => [],
        summary     => {},
        requires    => {},
        error       => undef,
        other_usage => undef,
        _struct     => $args{command_struct} || {},
    }, $class;

    my %config = (DEFAULT_CONFIG, %{$args{configure} || {}});
    my @gconf = grep $config{$_}, keys %config;
    Getopt::Long::Configure(@gconf) if @gconf;

    if (my $command_struct = $args{command_struct}) {
        for my $key (keys %$command_struct) {
            $self->{summary}{$key} = ucfirst($command_struct->{$key}->{desc} || '');
        }
    }

    if (my $global_struct = $args{global_struct}) {
        $self->_init_struct($global_struct);
        my $opthash = $self->_parse_struct;

        my @gopts;
        while (@ARGV) {
            last unless $ARGV[0] =~ /^-/;
            push @gopts, shift @ARGV;
        }

        if (@gopts) {
            $self->{ret} = GetOptionsFromArray(\@gopts, %$opthash);
            return $self unless $self->{ret};
        }
        return $self unless $self->_check_requires;
    }

    my $command_struct = $args{command_struct} || {};
    my $command_map = { map { $_ => 1 } keys %$command_struct };
    my $command = shift @ARGV;
    unless ($command) {
        $self->{ret} = 1;
        return $self;
    }

    unless ($command_map->{help}) {
        $command_map->{help} = 1;
        $args{command_struct}->{help} = {
            args => '[COMMAND]',
            desc => 'show help message',
        };
    }

    unless ($command_map->{$command}) {
        $self->{error} = "Unknown command: $command";
        $self->{ret} = 0;
        return $self;
    }

    $self->{command} = $command;

    if ($command eq 'help') {
        $self->{ret} = 0;
        return $self;
    }

    $self->_init_struct($command_struct->{$command}->{options});
    $self->_extends_usage($command_struct->{$command});
    my $opthash = $self->_parse_struct;
    $self->{ret} = GetOptionsFromArray(\@ARGV, %$opthash);
    $self->_check_requires;

    return $self;
}

sub command    { $_[0]->{command} }
sub status     { $_[0]->{ret}     }
sub is_success { $_[0]->{ret}     }
sub pod2usage  { carp 'Not implemented' }

sub opts {
    my($self) = @_;
    my $opt = $self->{opt};
    if ($self->{usage} && ($opt->{help} || $self->status == 0)) {
        if (defined $self->command && $self->command eq 'help') {
            delete $self->{command};
            if (defined(my $target = shift @ARGV)) {
                unless (ref $self->{_struct}{$target} eq 'HASH') {
                    $self->{error} = "Unknown command: $target";
                }
                else {
                    $self->{command} = $target;
                    $self->_init_struct($self->{_struct}{$target}{options});
                    $self->_extends_usage($self->{_struct}{$target});
                }
            }
        }

        # display usage message & exit
        print $self->usage;
        exit !$self->status;
    }
    return $opt;
}

sub usage {
    my($self) = @_;
    my $usage = "";
    my($v, @help, @commands);

    my($name, $version, $cmd, $struct, $args, $summary, $error, $other_usage) = map
        $self->{$_} || '', qw/name version cmd struct args summary error other_usage/;

    $usage .= "$error\n" if $error;

    if($name) {
        $usage .= $name;
        $usage .= " v$version" if $version;
        $usage .= "\n";
    }

    if ($self->command) {
        my $sub_command = $self->command;
        $usage .= "usage: $cmd $sub_command [options] $args\n\n";
    }
    else {
        $usage .= "usage: $cmd [options] COMMAND $args\n\n";
    }

    for my $o (@$struct) {
        my($opts, $desc) = @$o;
        next unless defined $desc;
        my @onames = $self->_option_names($opts);
        my $optname = join
            (', ', map { (length($_) > 1 ? '--' : '-').$_ } @onames);
        $optname = "    ".$optname unless length($onames[0]) == 1;
        push @help, [ $optname, ucfirst($desc) ];
    }

    require Text::Table;
    my $sep = \'   ';
    $usage .= "options:\n";
    $usage .= Text::Table->new($sep, '', $sep, '')->load(@help)->stringify."\n";

    unless ($self->command) {
        for my $command (sort keys %$summary) {
            push @commands, [ $command, $summary->{$command} ];
        }

        $usage .= "Implemented commands are:\n";
        $usage .= Text::Table->new($sep, '', $sep, '')->load(@commands)->stringify."\n";
        $usage .= "See '$cmd help COMMAND' for more information on a specific command.\n";
    }

    $usage .= "$other_usage\n" if defined $other_usage && length $other_usage > 0;

    return $usage;
}

sub show_usage {
    my ($self) = @_;
    print $self->usage;
    exit !$self->status;
}

sub _parse_struct {
    my ($self) = @_;
    my $struct = $self->{struct};

    my $opthash = {};
    for my $s (@$struct) {
        my($m, $descr, $spec, $ref, $opts) = @$s;
        my @onames = $self->_option_names($m);
        my($longname) = grep length($_) > 1, @onames;
        my $o = join('|', @onames).($spec || '');
        my $dest = $longname ? $longname : $onames[0];
        $opts ||= {};
        $self->{opt}{$dest} = exists $opts->{default} ? $opts->{default} : undef;
        if (ref $ref) {
            my $value = delete $self->{opt}{$dest};
            $$ref = $value if ref $ref && defined $value;
        }
        $opthash->{$o} = ref $ref ? $ref : \$self->{opt}{$dest};
        $self->{requires}{$dest} = 1 if $opts->{required};
    }
    return $opthash;
}

sub _init_struct {
    my ($self, $struct) = @_;
    $self->{struct} = $struct || [];

    if (ref $self->{modes} eq 'ARRAY') {
        my @modeopt;
        for my $m (@{$self->{modes}}) {
            my($mc) = $m =~ /^(\w)/;
            $mc = 'n' if $m eq 'test';
            push @modeopt, [[$mc, $m], qq($m mode)];
        }
        unshift @$struct, @modeopt;
    }

    unshift @{$self->{struct}}, [[qw(h help)], qq(this help message)]
        if $self->{usage} && !$self->_has_option('help');
}

sub _extends_usage {
    my ($self, $command_option) = @_;
    for my $key (qw/args other_usage/) {
        $self->{$key} = $command_option->{$key} if exists $command_option->{$key};
    }
}

sub _check_requires {
    my ($self) = @_;
    for my $dest (sort keys %{$self->{requires}}) {
        unless (defined $self->{opt}{$dest}) {
            $self->{ret}   = 0;
            $self->{error} = "`--$dest` option must be specified";
            return;
        }
    }
    return 1;
}

sub _option_names {
    my($self, $m) = @_;
    return sort {
        my ($la, $lb) = (length($a), length($b));
        return $la <=> $lb if $la < 2 or $lb < 2;
        return 0;
    } ref $m eq 'ARRAY' ? @$m : $m;
}

sub _has_option {
    my($self, $option) = @_;
    return 1 if grep { $_ eq $option } map { $self->_option_names($_->[0]) } @{$self->{struct}};
    return 0;
}

1;
__END__

=encoding utf-8

=for stopwords

=head1 NAME

Getopt::Compact::WithCmd - sub-command friendly, like Getopt::Compact

=head1 SYNOPSIS

insied foo.pl:

  use Getopt::Compact::WithCmd;
  
  my $go = Getopt::Compact::WithCmd->new(
     name          => 'foo',
     version       => '0.1',
     args          => 'FILE',
     global_struct => [
        [ [qw/f force/], 'force overwrite', '!', \my $force ],
     ],
     command_struct => {
        get => {
            options    => [
                [ [qw/d dir/], 'dest dir', '=s', undef, { default => '.' } ],
                [ [qw/o output/], 'output file name', '=s', undef, { required => 1 }],
            ],
            desc        => 'get file from url',
            args        => 'url',
            other_usage => 'blah blah blah',
        },
        remove => {
            ...
        }
     },
  );
  
  my $opts = $go->opts;
  my $cmd  = $go->command;
  
  if ($cmd eq 'get') {
      my $url = shift @ARGV;
  }

how will be like this:

  $ ./foo.pl -f get -o bar.html http://example.com/

usage, running the command './foo.pl -x' results in the following output:

  $ ./foo.pl -x
  Unknown option: x
  foo v0.1
  usage: hoge.pl [options] COMMAND FILE
  
  options:
     -h, --help    This help message
     -f, --force   Force overwrite
  
  Implemented commands are:
     get   Get file from url
  
  See 'hoge.pl COMMAND --help' for more information on a specific command.

in addition, running the command './foo.pl get' results in the following output:

  $ ./foo.pl get
  `--output` option must be specified
  foo v0.1
  usage: hoge.pl COMMAND [options] url
  
  options:
     -h, --help     This help message
     -d, --dir      Dest dir
     -o, --output   Output file name
  
  blah blah blah

=head1 DESCRIPTION

Getopt::Compact::WithCmd is yet another Getopt::* module.
This module is respected L<Getopt::Compact>.
This module is you can define of git-like option.
In addition, usage can be set at the same time.

=head1 METHODS

=head2 new(%args)

Create an object.
The option most Getopt::Compact compatible.
But I<struct> is cannot use.

The new I<%args> are:

=over

=item C<< global_struct($arrayref) >>

This option is sets common options across commands.
This option value is Getopt::Compact compatible.
In addition, extended to other values can be set.

  use Getopt::Compact::WithCmd;
  my $go = Getopt::Compact::WithCmd->new(
      global_struct => [
          [ $name_spec_arrayref, $description_scalar, $argument_spec_scalar, \$destination_scalar, $opt_hashref],
          [ ... ]
      ],
  );

I<$opt_hasref> are:

  {
      default  => $value, # default value
      required => $bool,
  }

=item C<< command_struct($hashref) >>

This option is sets sub-command and options.

  use Getopt::Compact::WithCmd;
  my $go = Getopt::Compact::WithCmd->new(
      command_struct => {
          $command => {
              options     => $options,
              args        => $args,
              desc        => $description,
              other_usage => $other_usage,
          },
      },
  );

I<$options>

This value is compatible to C<global_struct>.

I<$args>

command args.

I<$description>

command description.

I<$other_usage>

other usage message.
be added to the end of the usage message.

=back

=head2 opts

Returns a hashref of options keyed by option name.
Return value is merged global options and command options.

=head2 command

Gets sub-command name.

  # inside foo.pl
  use Getopt::Compact::WithCmd;
  
  my $go = Getopt::Compact::WithCmd->new(
     command_struct => {
        bar => {},
     },
  );
  
  print "command: ", $go->command, "\n";
  
  # running the command
  $ ./foo.pl bar
  bar

=head2 is_success

Alias of C<status>

  $go->is_success # == $go->status

=head2 usage

Gets usage message.

  my $message = $go->usage;

=head2 show_usage

Display usage message and exit.

  $go->show_usage;

=head2 pod2usage

B<Not implemented.>

=head1 AUTHOR

xaicron E<lt>xaicron {at} cpan.orgE<gt>

=head1 COPYRIGHT

Copyright 2010 - xaicron

=head1 LICENSE

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.

=head1 SEE ALSO

L<Getopt::Compact>

=cut
