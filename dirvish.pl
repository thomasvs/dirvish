
#       $Id: dirvish.pl,v 12.0 2004/02/25 02:42:15 jw Exp $  $Name: Dirvish-1_2 $

$VERSION = ('$Name: Dirvish-1_2_1 $' =~ /Dirvish/i)
	? ('$Name: Dirvish-1_2_1 $' =~ m/^.*:\s+dirvish-(.*)\s*\$$/i)[0]
	: '1.1.2 patch' . ('$Id: dirvish.pl,v 12.0 2004/02/25 02:42:15 jw Exp $'
		=~ m/^.*,v(.*:\d\d)\s.*$/)[0];
$VERSION =~ s/_/./g;

#########################################################################
#                                                         		#
#	Copyright 2002 and $Date: 2004/02/25 02:42:15 $
#                         Pegasystems Technologies and J.W. Schultz 	#
#                                                         		#
#	Licensed under the Open Software License version 2.0		#
#                                                         		#
#	This program is free software; you can redistribute it		#
#	and/or modify it under the terms of the Open Software		#
#	License, version 2.0 by Lauwrence E. Rosen.			#
#                                                         		#
#	This program is distributed in the hope that it will be		#
#	useful, but WITHOUT ANY WARRANTY; without even the implied	#
#	warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR		#
#	PURPOSE.  See the Open Software License for details.		#
#                                                         		#
#########################################################################



#########################################################
#		EXIT CODES
#
#	0       success
#	1-19    warnings
#	20-39   finalization error
#	40-49   post-* error
#	50-59   post-client error code % 10forwarded
#	60-69   post-server error code % 10forwarded
#	70-79   pre-* error
#	80-89   pre-server error code % 10 forwarded
#	90-99   pre-client error code % 10 forwarded
#	100-149 non-fatal error
#	150-199 fatal error
#	200-219 loadconfig error.
#	220-254 configuration error
#	255	usage error


use POSIX qw(strftime);
use Getopt::Long;
use Time::ParseDate;
use Time::Period;

@rsyncargs = qw(-vrltH --delete);

%RSYNC_CODES = (
	  0 => [ 'success',	"No errors" ],
	  1 => [ 'fatal',	"syntax or usage error" ],
	  2 => [ 'fatal',	"protocol incompatibility" ],
	  3 => [ 'fatal',	"errors selecting input/output files, dirs" ],
	  4 => [ 'fatal',	"requested action not supported" ],
	  5 => [ 'fatal',	"error starting client-server protocol" ],

	 10 => [ 'error',	"error in socket IO" ],
	 11 => [ 'error',	"error in file IO" ],
	 12 => [ 'check',	"error in rsync protocol data stream" ],
	 13 => [ 'check',	"errors with program diagnostics" ],
	 14 => [ 'error',	"error in IPC code" ],

	 20 => [ 'error',	"status returned when sent SIGUSR1, SIGINT" ],
	 21 => [ 'error',	"some error returned by waitpid()" ],
	 22 => [ 'error',	"error allocating core memory buffers" ],
	 23 => [ 'error',	"partial transfer" ],
#KHL 2005/02/18:  rsync code 24 changed from 'error' to 'warning'
	 24 => [ 'warning',	"file vanished on sender" ],

	 30 => [ 'error',	"timeout in data send/receive" ],

	124 => [ 'fatal',	"remote shell failed" ],
	125 => [ 'error',	"remote shell killed" ],
	126 => [ 'fatal',	"command could not be run" ],
	127 => [ 'fatal',	"command not found" ],
);

@BOOLEAN_FIELDS = qw(
	permissions
	checksum
	devices
	init
	numeric-ids
	sparse
	stats
	whole-file
	xdev
	zxfer
);

%RSYNC_OPT = (		# simple options
	permissions	=> '-pgo',
	devices		=> '-D',
	sparse		=> '-S',
	checksum	=> '-c',
	'whole-file'	=> '-W',
	xdev		=> '-x',
	zxfer		=> '-z',
	stats		=> '--stats',
	'numeric-ids'	=> '--numeric-ids',
);

%RSYNC_POPT = (		# parametered options
	'password-file'		=> '--password-file',
	'rsync-client'		=> '--rsync-path',
);

sub errorscan;
sub logappend;
sub scriptrun;
sub seppuku;

sub usage
{
	my $message = shift(@_);

	length($message) and print STDERR $message, "\n\n";

	$! and exit(255); # because getopt seems to send us here for death

	print STDERR <<EOUSAGE;
USAGE
	dirvish --vault vault OPTIONS [ file_list ]
	
OPTIONS
	--image image_name
	--config configfile
	--branch branch_name
	--reference branch_name|image_name
	--expire expire_date
	--init
	--reset option
	--summary short|long
	--no-run
EOUSAGE

	exit 255;
}

$Options = { 
	'Command-Args'	=> join(' ', @ARGV),
	'numeric-ids'	=> 1,
	'devices'	=> 1,
	permissions	=> 1,
	'stats'		=> 1,
	exclude		=> [ ],
	'expire-rule'	=> [ ],
	'rsync-option'	=> [ ],
	bank		=> [ ],
	'image-default'	=> '%Y%m%d%H%M%S',
	rsh		=> 'ssh',
	summary		=> 'short',
	config		=>
		sub {
			loadconfig('f', $_[1], $Options);
		},
	client		=>
		sub {
			$$Options{$_[0]} = $_[1];
			loadconfig('fog', "$CONFDIR/$_[1]", $Options);
		},
	branch		=>
		sub {
			if ($_[1] =~ /:/)
			{
				($$Options{vault}, $$Options{branch})
					= split(/:/, $_[1]);
			} else {
				$$Options{$_[0]} = $_[1];
			}
			loadconfig('f', "$$Options{branch}", $Options);
		},
	vault		=>
		sub {
			if ($_[1] =~ /:/)
			{
				($$Options{vault}, $$Options{branch})
					= split(/:/, $_[1]);
				loadconfig('f', "$$Options{branch}", $Options);
			} else {
				$$Options{$_[0]} = $_[1];
				loadconfig('f', 'default.conf', $Options);
			}
		},
	reset		=>
		sub {
			$$Options{$_[1]} = ref($$Options{$_[1]}) eq 'ARRAY'
				? [ ]
				: undef;
		},
	version		=> sub {
			print STDERR "dirvish version $VERSION\n";
			exit(0);
		},
	help		=> \&usage,
};

if ($CONFDIR =~ /dirvish$/ && -f "$CONFDIR.conf")
{
	loadconfig('f', "$CONFDIR.conf", $Options);
}
elsif (-f "$CONFDIR/master.conf")
{
	loadconfig('f', "$CONFDIR/master.conf", $Options);
}
elsif (-f "$CONFDIR/dirvish.conf")
{
	seppuku 250, <<EOERR;
ERROR: no master configuration file.
	An old $CONFDIR/dirvish.conf file found.
	Please read the dirvish release notes.
EOERR
}
else
{
	seppuku 251, "ERROR: no master configuration file";
}

GetOptions($Options, qw(
	config=s
	vault=s
	client=s
	tree=s
	image=s
	image-time=s
	expire=s
	branch=s
	reference=s
	exclude=s@
	sparse!
	zxfer!
	checksum!
	whole-file!
	xdev!
	speed-limit=s
	file-exclude|fexclude=s
	reset=s
	index=s
	init!
	summary=s
	no-run|dry-run
	help|?
	version
	)) or usage;

chomp($$Options{Server} = `hostname`);

if ($$Options{image})
{
	$image = $$Options{Image} = $$Options{image};
}
elsif ($$Options{'image-temp'})
{
	$image = $$Options{'image-temp'};
	$$Options{Image} = $$Options{'image-default'};
}
else
{
	$image = $$Options{Image} = $$Options{'image-default'};
}

$$Options{branch} =~ /:/
	and ($$Options{vault}, $$Options{branch})
		= split(/:/, $Options{branch});
$$Options{vault} =~ /:/
	and ($$Options{vault}, $$Options{branch})
		= split(/:/, $Options{vault});

for $key (qw(vault Image client tree))
{
	length($$Options{$key}) or usage("$key undefined");
	ref($$Options{$key}) eq 'CODE' and usage("$key undefined");
}

if(!$$Options{Bank})
{
	my $bank;
	for $bank (@{$$Options{bank}})
	{
		if (-d "$bank/$$Options{vault}")
		{
			$$Options{Bank} = $bank;
			last;
		}
	}
	$$Options{Bank} or seppuku 220, "ERROR: cannot find vault $$Options{vault}";
}
$vault = join('/', $$Options{Bank}, $$Options{vault});
-d $vault or seppuku 221, "ERROR: cannot find vault $$Options{vault}";

my $now = time;

if ($$Options{'image-time'})
{
	my $n = $now;

	$now = parsedate($$Options{'image-time'},
		DATE_REQUIRED => 1, NOW => $n);
	if (!$now)
	{
		$now = parsedate($$Options{'image-time'}, NOW => $n);
		$now > $n && $$Options{'image-time'} !~ /\+/ and $now -= 24*60*60;
	}
	$now or seppuku 222, "ERROR: image-time unparseable: $$Options{'image-time'}";
}
$$Options{'Image-now'} = strftime('%Y-%m-%d %H:%M:%S', localtime($now));

$$Options{Image} =~ /%/
	and $$Options{Image} = strftime($$Options{Image}, localtime($now));
$image =~ /%/
	and $image = strftime($image, localtime($now));

!$$Options{branch} || ref($$Options{branch})
	and $$Options{branch} = $$Options{'branch-default'} || 'default';

$seppuku_prefix = join(':', $$Options{vault}, $$Options{branch}, $image);

if (-d "$vault/$$Options{'image-temp'}" && $image eq $$Options{'image-temp'})
{
	my $iinfo;
	$iinfo = loadconfig('R', "$vault/$image/summary");
	$$iinfo{Image} or seppuku 223, "cannot cope with existing $image";
	if ($$Options{'no-run'})
	{
		print "ACTION: rename $vault/$image $vault/$$iinfo{Image}\n\n";
		$have_temp = 1;
	} else {
		rename ("$vault/$image", "$vault/$$iinfo{Image}");
	}
}

-d "$vault/$$Options{Image}" and seppuku 224, "ERROR: image $$Options{Image} already exists in $vault";
-d "$vault/$image" && !$have_temp and seppuku 225, "ERROR: image $image already exists in $vault";

$$Options{Reference} = $$Options{reference} || $$Options{branch};
if (!$$Options{init} && -f "$vault/dirvish/$$Options{Reference}.hist")
{
	my (@images, $i, $s);
	open(IMAGES, "$vault/dirvish/$$Options{Reference}.hist");
	@images = <IMAGES>;
	close IMAGES;
	while ($i = pop(@images))
	{
		$i =~ s/\s.*$//s;
		-d "$vault/$i/tree" or next;

		$$Options{Reference} = $i;
		last;
	}
}
$$Options{init} || -d "$vault/$$Options{Reference}"
	or seppuku 227, "ERROR: no images for branch $$Options{branch} found";

if(!$$Options{expire} && $$Options{expire} !~ /never/i
	&& scalar(@{$$Options{'expire-rule'}}))
{
	my ($rule, $p, $t, $e);
	my @cron;
	my @pnames = qw(min hr md mo wd);

	for $rule (reverse(@{$$Options{'expire-rule'}}))
	{
		if ($rule =~ /\{.*\}/)
		{
			($p, $e) = $rule =~ m/^(.*\175)\s*([^\175]*)$/;
		} else {
			@cron = split(/\s+/, $rule, 6);
			$e = $cron[5] || '';
			$p = '';
			for ($t = 0; $t < @pnames; $t++)
			{
				$cron[$t] eq '*' and next;
				($p .= "$pnames[$t] { $cron[$t] } ")
				=~ tr/,/ /;
			}
		}
		if (!$p)
		{
			$$Options{'Expire-rule'} = $rule;
			$$Options{Expire} = $e;
			last;
		}
		$t = inPeriod($now, $p);
		if ($t == 1)
		{
			$e ||= 'Never';
			$$Options{'Expire-rule'} = $rule;
			$$Options{Expire} = $e;
			last;
		}
		$t == -1 and printf STDERR "WARNING: invalid expire rule %s\n", $rule;
		next;
	}
} else {
	$$Options{Expire} = $$Options{expire};
}

$$Options{Expire} ||= $$Options{'expire-default'};

if ($$Options{Expire} && $$Options{Expire} !~ /Never/i)
{
	$$Options{Expire} .= strftime(' == %Y-%m-%d %H:%M:%S',
		localtime(parsedate($$Options{Expire}, NOW => $now)));
} else {
	$$Options{Expire} = 'Never';
}

#+SIS: KHL 2005-02-18  SpacesInSource fix
#-SIS: ($srctree, $aliastree) = split(/\s+/, $$Options{tree})
($srctree, $aliastree) = split(/[^\\]\s+/, $$Options{tree})
	or seppuku 228, "ERROR: no source tree defined";
$srctree =~ s(\\ )( )g;                     #+SIS
$srctree =~ s(/+$)();
$aliastree =~ s(/+$)();
$aliastree ||= $srctree;

$destree = join("/", $vault, $image, 'tree');
$reftree = join('/', $vault, $$Options{Reference}, 'tree');
$err_temp = join("/", $vault, $image, 'rsync_error.tmp');
$err_file = join("/", $vault, $image, 'rsync_error');
$log_file = join("/", $vault, $image, 'log');
$log_temp = join("/", $vault, $image, 'log.tmp');
$exl_file = join("/", $vault, $image, 'exclude');
$fsb_file = join("/", $vault, $image, 'fsbuffer');

while (($k, $v) = each %RSYNC_OPT)
{
	$$Options{$k} and push @rsyncargs, $v;
}

while (($k, $v) = each %RSYNC_POPT)
{
	$$Options{$k} and push @rsyncargs, $v . '=' . $$Options{$k};
}

$$Options{'speed-limit'}
	and push @rsyncargs, '--bwlimit=' . $$Options{'speed-limit'} * 100;

scalar @{$$Options{'rsync-option'}}
	and push @rsyncargs, @{$$Options{'rsync-option'}};

scalar @{$$Options{exclude}}
	and push @rsyncargs, '--exclude-from=' . $exl_file;

if (!$$Options{'no-run'})
{
	mkdir "$vault/$image", 0700
		or seppuku 230, "mkdir $vault/$image failed";
	mkdir $destree, 0755;

	open(SUMMARY, ">$vault/$image/summary")
		or seppuku 231, "cannot create $vault/$image/summary"; 
} else {
	open(SUMMARY, ">-");
}

$Set = $Unset = '';
for (@BOOLEAN_FIELDS)
{
	$$Options{$_}
		and $Set .= $_ . ' '
		or $Unset .= $_ . ' ';
}

@summary_fields = qw(
	client tree rsh
	Server Bank vault branch
       	Image image-temp Reference
	Image-now Expire Expire-rule
	exclude
	rsync-option
	Enabled
);
$summary_reset = 0;
for $key (@summary_fields, 'RESET', sort(keys(%$Options)))
{
	if ($key eq 'RESET')
       	{
		$summary_reset++;
		$Set and print SUMMARY "SET $Set\n";
		$Unset and print SUMMARY "UNSET $Unset\n";
		print SUMMARY "\n";
		$$Options{summary} ne 'long' && !$$Options{'no-run'} and last;
		next;
	}
	grep(/^$key$/, @BOOLEAN_FIELDS) and next;
	$summary_reset && grep(/^$key$/, @summary_fields) and next;

	$val = $$Options{$key};
	if(ref($val) eq 'ARRAY')
	{
		my $v;
		scalar(@$val) or next;
		print SUMMARY "$key:\n";
		for $v (@$val)
		{
			printf SUMMARY "\t%s\n", $v;
		}
	}
	ref($val) and next;
	$val or next;
	printf SUMMARY "%s: %s\n", $key, $val;
}

$$Options{init} or push @rsyncargs, "--link-dest=$reftree";

$rclient = undef;
$$Options{client} ne $$Options{Server}
	and $rclient = $$Options{client} . ':';

$ENV{RSYNC_RSH} = $$Options{rsh};

@cmd = (
	($$Options{rsync} ? $$Options{rsync} : 'rsync'),
	@rsyncargs,
	$rclient . $srctree . '/',
	$destree
	);
printf SUMMARY "\n%s: %s\n", 'ACTION', join (' ', @cmd);

$$Options{'no-run'} and exit 0;

printf SUMMARY "%s: %s\n", 'Backup-begin', strftime('%Y-%m-%d %H:%M:%S', localtime);

$env_srctree = $srctree;		#+SIS:
$env_srctree =~ s/ /\\ /g;		#+SIS:

$WRAPPER_ENV = sprintf (" %s=%s" x 5,
	'DIRVISH_SERVER', $$Options{Server},
	'DIRVISH_CLIENT', $$Options{client},
#-SIS:	'DIRVISH_SRC', $srctree,
	'DIRVISH_SRC', $env_srctree,	#+SIS:
	'DIRVISH_DEST', $destree,
	'DIRVISH_IMAGE', join(':',
		$$Options{vault},
		$$Options{branch},
		$$Options{Image}),
);

if(scalar @{$$Options{exclude}})
{
	open(EXCLUDE, ">$exl_file");
	for (@{$$Options{exclude}})
	{
		print EXCLUDE $_, "\n";
	}	
	close(EXCLUDE);
	$ENV{DIRVISH_EXCLUDE} = $exl_file;
}

if ($$Options{'pre-server'})
{
	$status{'pre-server'} = scriptrun(
		lable	=> 'Pre-Server',
		cmd	=> $$Options{'pre-server'},
		now	=> $now,
		log	=> $log_file,
		dir	=> $destree,
		env	=> $WRAPPER_ENV,
	);

	if ($status{'pre-server'})
	{
		my $s = $status{'pre-server'} >> 8;
		printf SUMMARY "pre-server failed (%d)\n", $s;
		printf STDERR "%s:%s pre-server failed (%d)\n",
			$$Options{vault}, $$Options{branch},
			$s;
		exit 80 + ($s % 10);
	}
}

if ($$Options{'pre-client'})
{
	$status{'pre-client'} = scriptrun(
		lable	=> 'Pre-Client',
		cmd	=> $$Options{'pre-client'},
		now	=> $now,
		log	=> $log_file,
		dir	=> $srctree,
		env	=> $WRAPPER_ENV,
		shell	=> (($$Options{client} eq $$Options{Server})
			?  undef
			: "$$Options{rsh} $$Options{client}"),
	);
	if ($status{'pre-client'})
	{
		my $s = $status{'pre-client'};
		printf SUMMARY "pre-client failed (%d)\n", $s;
		printf STDERR "%s:%s pre-client failed (%d)\n",
			$$Options{vault}, $$Options{branch},
			$s;

		($$Options{'pre-server'}) && scriptrun(
			lable	=> 'Post-Server',
			cmd	=> $$Options{'post-server'},
			now	=> $now,
			log	=> $log_file,
			dir	=> $destree,
			env	=> $WRAPPER_ENV . ' DIRVISH_STATUS=fail',
		);
		exit 90 + ($s % 10);
	}
}

# create a buffer to allow logging to work after full fileystem
open (FSBUF, ">$fsb_file");
print FSBUF "         \n" x 6553;
close FSBUF;

for ($runloops = 0; $runloops < 5; ++$runloops)
{
	logappend($log_file, sprintf("\n%s: %s\n", 'ACTION', join(' ', @cmd)));

		# create error file and connect rsync STDERR to it.
		# preallocate 64KB so there will be space if rsync
		# fills the filesystem.
	open (INHOLD, "<&STDIN");
	open (ERRHOLD, ">&STDERR");
	open (STDERR, ">$err_temp");
	print STDERR "         \n" x 6553;
	seek STDERR, 0, 0;

	open (OUTHOLD, ">&STDOUT");
	open (STDOUT, ">$log_temp");

	$status{code} = (system(@cmd) >> 8) & 255;

	open (STDERR, ">&ERRHOLD");
	open (STDOUT, ">&OUTHOLD");
	open (STDIN, "<&INHOLD");

	open (LOG_FILE, ">>$log_file");
	open (LOG_TEMP, "<$log_temp");
	while (<LOG_TEMP>)
	{
		chomp;
		m(/$) and next;
		m( [-=]> ) and next;
		print LOG_FILE $_, "\n";
	}
	close (LOG_TEMP);
	close (LOG_FILE);
	unlink $log_temp;

	$status{code} and errorscan(\%status, $err_file, $err_temp);

	$status{warning} || $status{error}
       		and logappend($log_file, sprintf(
			"RESULTS: warnings = %d, errors = %d",
			$status{warning}, $status{error}
			)
		);
	if ($RSYNC_CODES{$status{code}}[0] eq 'check')
	{
		$status{fatal} and last;
		$status{error} or last;
	} else {
		$RSYNC_CODES{$status{code}}[0] eq 'fatal' and last;
		$RSYNC_CODES{$status{code}}[0] eq 'error' or last;
	}
}

scalar @{$$Options{exclude}} && unlink $exl_file;
-f $fsb_file and unlink $fsb_file;

if ($status{code})
{
	if ($RSYNC_CODES{$status{code}}[0] eq 'check')
	{
		if ($status{fatal})		{ $Status = 'fatal'; }
		elsif ($status{error})		{ $Status = 'error'; }
		elsif ($status{warning})	{ $Status = 'warning'; }
		$Status_msg = sprintf "%s (%d) -- %s",
			($Status eq 'fatal' ? 'fatal error' : $Status),
			$status{code},
			$status{message}{$Status};
	} elsif ($RSYNC_CODES{$status{code}}[0] eq 'fatal')
	{
		$Status_msg = sprintf "fatal error (%d) -- %s",
			$status{code},
			$RSYNC_CODES{$status{code}}[1];
	}

	if (!$Status_msg)
	{
		$RSYNC_CODES{$status{code}}[0] eq 'fatal' and $Status = 'fatal';
		$RSYNC_CODES{$status{code}}[0] eq 'error' and $Status = 'error';
		$RSYNC_CODES{$status{code}}[0] eq 'warning' and	$Status = 'warning';
		$RSYNC_CODES{$status{code}}[0] eq 'check' and $Status = 'unknown';
		exists $RSYNC_CODES{$status{code}} or $Status = 'unknown';
		$Status_msg = sprintf "%s (%d) -- %s",
			($Status eq 'fatal' ? 'fatal error' : $Status),
			$status{code},
			$RSYNC_CODES{$status{code}}[1];
	}
	if ($Status eq 'fatal' || $Status eq 'error' || $status eq 'unknown')
	{
		printf STDERR "dirvish %s:%s %s\n",
			$$Options{vault}, $$Options{branch},
			$Status_msg;
	}
} else {
	$Status = $Status_msg = 'success';
}
$WRAPPER_ENV .= ' DIRVISH_STATUS=' .  $Status;

if ($$Options{'post-client'})
{
	$status{'post-client'} = scriptrun(
		lable	=> 'Post-Client',
		cmd	=> $$Options{'post-client'},
		now	=> $now,
		log	=> $log_file,
		dir	=> $srctree,
		env	=> $WRAPPER_ENV,
		shell	=> (($$Options{client} eq $$Options{Server})
			?  undef
			: "$$Options{rsh} $$Options{client}"),
	);
	if ($status{'post-client'})
	{
		my $s = $status{'post-client'} >> 8;
		printf SUMMARY "post-client failed (%d)\n", $s;
		printf STDERR "%s:%s post-client failed (%d)\n",
			$$Options{vault}, $$Options{branch},
			$s;
	}
}

if ($$Options{'post-server'})
{
	$status{'post-server'} = scriptrun(
		lable	=> 'Post-Server',
		cmd	=> $$Options{'post-server'},
		now	=> $now,
		log	=> $log_file,
		dir	=> $destree,
		env	=> $WRAPPER_ENV,
	);
	if ($status{'post-server'})
	{
		my $s = $status{'post-server'} >> 8;
		printf SUMMARY "post-server failed (%d)\n", $s;
		printf STDERR "%s:%s post-server failed (%d)\n",
			$$Options{vault}, $$Options{branch},
			$s;
	}
}

if($status{fatal})
{
	system ("rm -rf $destree");
	unlink $err_temp;
	printf SUMMARY "%s: %s\n", 'Status', $Status_msg;
	exit 199;
} else {
	unlink $err_temp;
	-z $err_file and unlink $err_file;
}

printf SUMMARY "%s: %s\n",
	'Backup-complete', strftime('%Y-%m-%d %H:%M:%S', localtime);

printf SUMMARY "%s: %s\n", 'Status', $Status_msg;

# We assume warning and unknown produce useful results
$Status eq 'warning' || $Status eq 'unknown' and $Status = 'success';

if ($Status eq 'success')
{
	-s "$vault/dirvish/$$Options{branch}.hist" or $newhist = 1;
	if (open(HIST, ">>$vault/dirvish/$$Options{branch}.hist"))
	{
		$newhist == 1 and printf HIST ("#%s\t%s\t%s\t%s\n",
				qw(IMAGE CREATED REFERECE EXPIRES));
		printf HIST ("%s\t%s\t%s\t%s\n",
				$$Options{Image},
				strftime('%Y-%m-%d %H:%M:%S', localtime),
				$$Options{Reference} || '-',
				$$Options{Expire}
			);
		close (HIST);
	}
} else {
	printf STDERR "dirvish error: branch %s:%s image %s failed\n",
		$vault, $$Options{branch}, $$Options{Image};
}

length($$Options{'meta-perm'})
	and chmod oct($$Options{'meta-perm'}),
		"$vault/$image/summary",
		"$vault/$image/rsync_error",
		"$vault/$image/log";

$Status eq 'success' or exit 149;

$$Options{log} =~ /.*(gzip)|(bzip2)/
	and system "$$Options{log} $vault/$image/log";

if ($$Options{index} && $$Options{index} !~/^no/i)
{
	
	open(INDEX, ">$vault/$image/index");
	open(FIND, "find $destree -ls|") or seppuku 21, "dirvish $vault:$image cannot build index";
	while (<FIND>)
	{
		s/ $destree\// $aliastree\//g;
		print INDEX $_ or seppuku 22, "dirvish $vault:$image error writing index";
	}
	close FIND;
	close INDEX;

	length($$Options{'meta-perm'})
		and chmod oct($$Options{'meta-perm'}), "$vault/$image/index";
	$$Options{index} =~ /.*(gzip)|(bzip2)/
		and system "$$Options{index} $vault/$image/index";
}

chmod oct($$Options{'image-perm'}) || 0755, "$vault/$image";

exit 0;

sub errorscan
{
	my ($status, $err_file, $err_temp) = @_;
	my $err_this_loop = 0;
	my ($action, $pattern, $severity, $message);
	my @erraction = (
		[ 'fatal',	'^ssh:.*nection refused',		],
		[ 'fatal',	'^\S*sh: .* No such file',		],
		[ 'fatal',	'^ssh:.*No route to host',		],
		[ 'error',	'^file has vanished: ',			],
		[ 'warning',	'readlink .*: no such file or directory', ],

		[ 'fatal',	'failed to write \d+ bytes:',
			'write error, filesystem probably full'		],
		[ 'fatal',	'write failed',
			'write error, filesystem probably full'		],
		[ 'error',	'error: partial transfer',
			'partial transfer'				],
		[ 'error',	'error writing .* exiting: Broken pipe',
			'broken pipe'					],
	);

	open (ERR_FILE, ">>$err_file");
	open (ERR_TEMP, "<$err_temp");
	while (<ERR_TEMP>)
	{
		chomp;
		s/\s+$//;
		length or next;
		if (!$err_this_loop)
		{
			printf ERR_FILE "\n\n*** Execution cycle %d ***\n\n",
				$runloops;
			$err_this_loop++
		}
		print ERR_FILE $_, "\n";

		$$status{code} or next;
		
		for $action (@erraction)
		{
			($severity, $pattern, $message) = @$action;
			/$pattern/ or next;

			++$$status{$severity};
			$msg = $message || $_;
			$$status{message}{$severity} ||= $msg;
			logappend($log_file, $msg);
			$severity eq 'fatal'
				and printf STDERR "dirvish %s:%s fatal error: %s\n",
					$$Options{vault}, $$Options{branch},
					$msg;
			last;
		}
		if (/No space left on device/)
		{
			$msg = 'filesystem full';
			$$status{message}{fatal} eq $msg and next;

			-f $fsb_file and unlink $fsb_file;
			++$$status{fatal};
			$$status{message}{fatal} = $msg;
			logappend($log_file, $msg);
			printf STDERR "dirvish %s:%s fatal error: %s\n",
				$$Options{vault}, $$Options{branch},
				$msg;
		}
		if (/error: error in rsync protocol data stream/)
		{
			++$$status{error};
			$msg = $message || $_;
			$$status{message}{error} ||= $msg;
			logappend($log_file, $msg);
		}
	}
	close ERR_TEMP;
	close ERR_FILE;
}

sub logappend
{
	my ($file, @messages) = @_;
	my $message;

	open (LOGFILE, '>>' . $file) or seppuku 20, "cannot open log file $file";
	for $message (@messages)
	{
		print LOGFILE $message, "\n";
	}
	close LOGFILE;
}

sub scriptrun
{
	my (%A) = @_;
	my ($cmd, $rcmd, $return);

	$A{now} ||= time;
	$A{log} or seppuku 229, "must specify logfile for scriptrun()";
	ref($A{cmd}) and seppuku 232, "$A{lable} option specification error";

	$cmd = strftime($A{cmd}, localtime($A{now}));

#KHL 2005-02-18 BadShellCommandCWD:  fix inverted logic
#	if ($A{dir} =~ /^:/)
	if ($A{dir} !~ /^:/)
	{
		$rcmd = sprintf ("%s 'cd %s; %s %s' >>%s",
			($A{shell} || "/bin/sh -c"),
			$A{dir}, $A{env},
			$cmd,
			$A{log}
		);
	} else {
		$rcmd = sprintf ("%s '%s %s' >>%s",
			($A{shell} || "/bin/sh -c"),
			$A{env},
			$cmd,
			$A{log}
		);
	}

	$A{lable} =~ /^Post/ and logappend($A{log}, "\n");

	logappend($A{log}, "$A{lable}: $cmd");

	$return = system($rcmd);

	$A{lable} =~ /^Pre/ and logappend($A{log}, "\n");

	return $return;
}

