#!/usr/bin/env perl

use 5.042;
no source::encoding;
use warnings FATAL => 'all';
use warnings::unused;
use autodie ':default';
use Util 'ref_to_json_file';
use Capture::Tiny 'capture';
use Term::ANSIColor;
use Getopt::ArgParse;
use List::Compare;
use List::Util qw(min max);

# this is kind of like my nextFlow, as I understand it

sub execute ($cmd, $return = 'exit', $die = 1) {
	if ($return !~ m/^(exit|stdout|stderr|all)$/) {
		die "you gave \$return = \"$return\", while this subroutine only accepts ^(exit|stdout|stderr)\$";
	}
	my ($stdout, $stderr, $exit) = capture {
		system( $cmd )
	};
	if (($die == 1) && ($exit != 0)) {
		say STDERR "exit = $exit";
		say STDERR "STDOUT = $stdout";
		say STDERR "STDERR = $stderr";
		die "$cmd\n failed";
	}
	if ($return eq 'exit') {
		return $exit
	} elsif ($return eq 'stderr') {
		chomp $stderr;
		return $stderr
	} elsif ($return eq 'stdout') {
		chomp $stdout;
		return $stdout
	} elsif ($return eq 'all') {
		chomp $stdout;
		chomp $stderr;
		return {
			exit   => $exit, 
			stdout => $stdout, 
			stderr => $stderr
		}
	} else {
		die "$return broke pigeonholes"
	}
	return $stdout
}

# now copy inputs from $args that aren't files into the input hash
my $parser = Getopt::ArgParse->new_parser(
	prog         => 'Automate running GROMACS simulations',
	description  => 'Automating running GROMACS simulations, avoiding errors when moving from one step to the next by a checked (not necessarily perfect!) pipeline',
	epilog       => "Example:\nperl 0.run.gromacs.pl --emin input/emin-charmm.0.mdp -npt input/npt-charmm.mdp --gmx /home/con/prog/gromacs-2025.3/build/bin/gmx --nvt input/nvt-charmm.mdp --pdb 1uao.noH.pdb -production input/md-charmm.mdp --o --log-file \n"
);
$parser->add_args(
	['--emin-input-file', '-emin', required => 1, help => 'Energy minimization input file', type => 'Scalar'],
	['--force-field', '-ff', required => 0, help => 'The force field desired, e.g. "charmm27"', type => 'Scalar', default => 'charmm27'],
	['--gmx', required => 1, help => 'gmx executable', type => 'Scalar'],
	['--ignore-H', required => 1, help => 'pmx pdb2gmx ignore Hydrogens', default => 0, type => 'Bool'],
	['--log-file', '-l', required => 1, help => 'Put all commands that were run into this log file', type => 'Scalar'],
	['--npt-input-file', '-npt', required => 1, help => 'Pressure Equilibration input file: Number of particles, Pressure, and Temperature are held constant', type => 'Scalar'],
	['--nvt-input-file', '-nvt', required => 1, help => 'Equilibration run - temperature: constant Number of particles, Volume, and Temperature', type => 'Scalar'],
	['--overwrite', '-o', type => 'Bool', default => 0, help => 'Overwrite old output files, by default off. All previous checkpoint files will be deleted.', required => 0],
	['--pdb', '-p', type => 'Scalar', required => 1, help => 'Input PDB file; Perhaps better without H?'],
	['--production-input-file', '-production', required => 0, type => 'Scalar', help => 'Production Input File'],
	['--water', '-w', type => 'Scalar', default => 'tip3p', help => 'Water model (e.g. "tip3p")', required => 0]
);
sub list_regex_files {
	my $regex = shift;
	my @files;
	opendir (my $dh, '.');
	$regex = qr/$regex/;
	while (my $file = readdir $dh) {
		next if $file !~ $regex;
		next if $file =~ m/^\.{1,2}$/;
		next unless -f $file;
		push @files, $file
	}
	@files
}
my $args = $parser->parse_args( @ARGV );
my %input;
# put all inputs that are files here, so that I can check if any are missing before I start long jobs
$input{npt} = $args->npt_input_file;
$input{nvt} = $args->nvt_input_file;
$input{emin} = $args->emin_input_file;
$input{pdb} = $args->pdb;
if ($args->production_input_file) {
	$input{production_input_file} = $args->production_input_file;
}

my @missing_input_files = grep {not -f $_} values %input;
if (scalar @missing_input_files > 0) {
	p @missing_input_files;
	die 'the above files do not exist or are not files';
}
# now copy inputs from $args that aren't files into the input hash
$input{water} = $args->water;
$input{force_field} = $args->force_field;
if ($args->gmx) {
	$input{gmx} = $args->gmx;
} else {
	$input{gmx} = 'gmx';
}
open my $log, '>', $args->log_file;
p($args, output => $log);
if ($args->overwrite) {
   foreach my $file (list_regex_files('^#.+#$')) {
      say $log "deleting $file, which could disrupt future calculations";
      unlink $file;
   }
   $input{overwrite} = 'True';
} else {
   $input{overwrite} = 'False';
}

sub job ($cmd, $die = 1, @product_files) {
	say 'The command is ' . colored(['blue on_bright_red'], $cmd);
	if (scalar @product_files == 0) {
		die "no product files were entered for cmd: $cmd";
	}
	my @existing_files = grep {-f $_} @product_files;
	my %r = (
		cmd             => $cmd,
		'product.files' => [@product_files],
	);
	if (($input{overwrite} eq 'False') && (scalar @existing_files > 0)) { # this has been done before
		say colored(['black on_green'], "\"$cmd\"\n has been done before");
		$r{done} = 'before';
		p(%r, output => $log);
#		p %r;
		return \%r;
	}
	($r{stdout}, $r{stderr}, $r{'exit'}) = capture {
		system( $cmd );
	};
	$r{done} = 'now';
#	p %r;
	p(%r, output => $log);
	if (($die == 1) && ($r{'exit'} != 0)) {
		p %r;
		die "$cmd failed"
	}
	return \%r;
}
#------------
mkdir 'json' unless -d 'json';
my $processed_gro = $input{pdb};
   $processed_gro =~ s/pdb$/gro/;
my $topol = 'topol.top';
# generate topology
my $ignore_H = '';
if ($args->ignore_H) {
	$ignore_H = '-ignh';
}
my $r = job("$input{gmx} pdb2gmx -f $input{pdb} $ignore_H -o $processed_gro -water $input{water} -ff $input{force_field}", 1, $processed_gro, $topol);
p $r;
#------------
# Defining the simulation box
#------------
my $new_box = $processed_gro;
$new_box =~ s/gro$/newbox.gro/;
$r = job("$input{gmx} editconf -f $processed_gro -o $new_box -c -d 1.0 -bt dodecahedron", 1, $new_box);
p $r;
#------------
# fill the box with water
#------------
my $solv = $new_box;
$solv =~ s/newbox.gro$/solv.gro/;
$r = job("$input{gmx} solvate -cp $new_box -cs spc216.gro -o $solv -p $topol", 1, $solv);
p $r;
#------------
# prepare input for gmx genion
#------------
#.mdp: "molecular dynamics parameter" file that specifies all relevant settings for performing a calculation or simulation
my $ions_mdp = 'ions.mdp';
$r = job("touch $ions_mdp", 1, $ions_mdp);
p $r;
my $ions_tpr = 'ions.tpr';
$r = job("$input{gmx} grompp -f $ions_mdp -c $solv -p topol.top -o $ions_tpr", 1, $ions_tpr);
p $r;
my $solv_ions = $solv;
$solv_ions =~ s/solv\.gro$/solv_ions.gro/;
unlink $solv_ions if -f $solv_ions;
$r = job("printf \"SOL\\n\" | $input{gmx} genion -s $ions_tpr -o $solv_ions -conc 0.15 -p $topol -pname NA -nname CL -neutral", 1, $solv_ions);
p $r;
#--------------
# energy minimization
#--------------
my $em_tpr = 'em.tpr'; # .tpr: a binary run input file that combines coordinates, topology, all associated force field parameters, and all input settings defined in the .mdp file
$r = job( "$input{gmx} grompp -f $input{emin} -c $solv_ions -p $topol -o $em_tpr", 1, $em_tpr);
my ($em_log, $em_gro, $em_trr, $em_edr) = ('em.log', 'em.gro', 'em.trr', 'em.edr');
p $r;
say '---------------';
say '--Now running energy minimization';
say '---------------';
$r = job( "$input{gmx} mdrun -v -deffnm em", 1, $em_log, $em_gro, $em_trr, $em_edr);
#------------
# Equilibration run - temperature
# first phase is conducted under an NVT ensemble (constant Number of particles, Volume, and Temperature)
#--------------
my $nvt_tpr = 'nvt.tpr';
$r = job("$input{gmx} grompp -f $input{nvt} -c $em_gro -r $em_gro -p $topol -o $nvt_tpr", 1, $nvt_tpr);
my ($nvt_log, $nvt_edr, $nvt_gro, $nvt_cpt) = ('nvt.log', 'nvt.edr', 'nvt.gro', 'nvt.cpt');
# checkpoint file is "cpt"
# comment out if debugging, it's slow
$r = job("$input{gmx} mdrun -v -deffnm nvt", 1, $nvt_log, $nvt_edr, $nvt_gro, $nvt_cpt);
#------------
# Equilibration run - pressure
# Number of particles, Pressure, and Temperature are held constant (isothermal/isobaric)
#------------
my $npt_tpr = 'npt.tpr';
$r = job("$input{gmx} grompp -f $input{npt} -c $nvt_gro -r $nvt_gro -t $nvt_cpt -p $topol -o $npt_tpr", 1, $npt_tpr);
my ($npt_edr, $npt_gro, $npt_cpt) = ('npt.edr', 'npt.gro', 'npt.cpt');
$r = job("$input{gmx} mdrun -v -deffnm npt", 1, $npt_edr, $npt_gro, $npt_cpt);
my $chain_ndx = 'npt.chains.ndx';
$r = job("printf \"splitch 1\\nq\\n\" | $input{gmx} make_ndx -f nvt.tpr -o $chain_ndx", 1, $chain_ndx);
# view the output from above thus: gmx check -n npt.chains.ndx
#------------
# Production run
#------------
my $md_tpr = 'md.tpr';
$r = job("$input{gmx} grompp -f $input{production_input_file} -c $npt_gro -t $npt_cpt -p $topol -o $md_tpr", 1, $md_tpr);
my ($md_log, $md_edr, $md_gro, $md_xtc, $md_prev_cpt) = ('md.log', 'md.edr', 'md.gro', 'md.xtc', 'md_prev.cpt');
job("$input{gmx} mdrun -v -deffnm md", 1, $md_log, $md_edr, $md_gro, $md_xtc, $md_prev_cpt);
#------------
# Analysis
#------------
my $md_center = 'md_center.xtc';
job("printf \"1\\n1\\n\" | $input{gmx} trjconv -s $md_tpr -f $md_xtc -o $md_center -center -pbc mol", 1, $md_center);

job("printf \"1\\n1\\n\" | $input{gmx} mindist -s md.tpr -f $md_center -pi -od mindist.xvg", 1, 'mindist.xvg');
my $rmsd_xray = 'rmsd_xray.xvg';
job("printf \"4\\n1\\n\" | $input{gmx} rms -s $em_tpr -f $md_center -o $rmsd_xray -tu ns -xvg none", 1, $rmsd_xray);

# Measure compactness with radius of gyration
my $gyrate_xvg = 'gyrate.xvg';
job("echo 1 | $input{gmx} gyrate -f md_center.xtc -s md.tpr -o $gyrate_xvg -xvg none", 1, $gyrate_xvg);
say 'wrote ' . colored(['green on_black'], $args->log_file);
#----------
# only consider protein
#----------
my $protein_gro = 'protein.gro';
job("printf \"1\\n1\\n\" | $input{gmx} trjconv -s md.tpr -f npt.gro -o $protein_gro -pbc mol -ur compact -center", 1, $protein_gro);
my $protein_tpr = 'protein.tpr';
job("printf \"1\\n1\\n\" | $input{gmx} convert-tpr -s md.tpr -o $protein_tpr", 1, $protein_tpr);
my $rmsd_matrix = 'rmsd.matrix.xpm';
my $rmsd_dat    = 'rmsd.bin.dat';
job("printf \"1\\n1\\n\" | $input{gmx} rms -s md.tpr -f md.xtc -m $rmsd_matrix -m ", 1, $rmsd_matrix, $rmsd_dat);# 1-1 is protein-protein
my $ndx_str = execute("$input{gmx} check -n $chain_ndx", 'stdout');
p $ndx_str;
my @ndx = split /\n/, $ndx_str;
my @header = split /\h+/, $ndx[2];
shift @header;
splice @ndx, 0, 3; # remove top lines, not useful
my @group;
foreach my $line (@ndx) {
	$line =~ s/^\h+\d+\h+//;
	say $line;
	my @line = split /\h+/, $line;
	if (scalar @header == 0) {
		@header = @line;
		next;
	}
	my %line;
	@line{@header} = @line;
	push @group, $line{'Group'};
}
ref_to_json_file(\@group, 'json/group.json');
p @group, array_max => scalar @group;
mkdir 'hbond' unless -d 'hbond';
=ndx
Nr.   Group               #Entries   First    Last
   0  System                 18848       1   18848
   1  Protein                 1231       1    1231
   2  Protein-H                602       1    1231
   3  C-alpha                   76       5    1226
   4  Backbone                 228       1    1229
   5  MainChain                303       1    1229
   6  MainChain+Cb             373       1    1229
   7  MainChain+H              378       1    1229
   8  SideChain                853       6    1231
   9  SideChain-H              299       7    1231
  10  Prot-Masses             1231       1    1231
  11  non-Protein            17617    1232   18848
  12  Water                  17583    1232   18814
  13  SOL                    17583    1232   18814
  14  non-Water               1265       1   18848
  15  Ion                       34   18815   18848
  16  Water_and_ions         17617    1232   18848
=cut
my ($key, %ndx_group, %hbond, $type);
# get a list of what atom numbers are in which groups, to prevent hbond errors
open my $fh, '<', 'npt.chains.ndx';
while (<$fh>) {
	if (/^\[\h+(\H+)\h+\]/) {
		$key = $1;
		next;
	}
	chomp;
	my @line = split;
	push @{ $ndx_group{$key} }, @line;
}
close $fh;
ref_to_json_file(\%ndx_group, 'json/ndx.group.json');
my $hbond_ndx = 'hbond.ndx';
unlink $hbond_ndx if -f $hbond_ndx;
job("printf \"0\\n0\\n\" | $input{gmx} hbond -s md.tpr -f md.xtc", 1, $hbond_ndx);
open $fh, '<', $hbond_ndx;
while (<$fh>) {
	last if /^\[\h+hbonds_System/;
	if (/^\[\h+(donor|acceptor)/) {
		$type = $1;
		next;
	}
	if ((/^\[\h+(\w+)/) && ($1 !~ m/^(donor|acceptor)/)) {
		say "$_ undeffing and moving on ";
		undef $type;
		next;
	}
	next unless defined $type;
	my @line = split;
	push @{ $hbond{$type} }, @line;
}
close $fh;
ref_to_json_file(\%hbond, 'json/hbond.json');
my @undef_keys = grep {not defined $hbond{$_}} ('acceptor','donor');
if (scalar @undef_keys > 0) {
	p @undef_keys;
	die "Couldn't get hbond acceptor or donor atoms, the above types are empty";
}
my (%groups_without_hbonding,%n_hbond);
foreach my $g (@group) {
	my $lc = List::Compare->new($hbond{'donor'}, $ndx_group{$g});
	my @donors = $lc->get_intersection;
	$n_hbond{$g}{'donor'}    = \@donors;
	$lc    = List::Compare->new($hbond{'acceptor'}, $ndx_group{$g});
	my @acceptors = $lc->get_intersection;
	$n_hbond{$g}{'acceptor'} = \@acceptors;
	if (scalar @donors == scalar @acceptors == 0) {
		say $log "$g has neither donors nor acceptors";
		$groups_without_hbonding{$g} = 1;
	}
}
ref_to_json_file(\%groups_without_hbonding, 'json/groups.without.hbonding.json');
ref_to_json_file(\%n_hbond, 'json/n.hbond.json');
foreach my ($g1i, $g1) (indexed @group) {
	next if defined $groups_without_hbonding{$g1};
	next if $g1 eq 'System';
	foreach my ($g2i, $g2) (indexed @group) {
		if (
				($g2 eq 'System') ||
				($g1i == $g2i)
			) {
			next;
		}
		next if defined $groups_without_hbonding{$g2};
		if (
				scalar @{ $n_hbond{$g1}{'acceptor'} } == 0 == scalar @{ $n_hbond{$g2}{'acceptor'} }
			) {
			say $log "$g1 & $g2 have 0 acceptors";
			next;
		}
		if (
				scalar @{ $n_hbond{$g1}{'donor'} } == 0 == scalar @{ $n_hbond{$g2}{'donor'} }
			) {
			say $log "$g1 & $g2 have 0 donors";
			next;
		}
		my $lc = List::Compare->new($ndx_group{$g1}, $ndx_group{$g2});
#		printf("Range of $g1: [%u-%u]\n", min(@{ $ndx_group{$g1} }), max(@{ $ndx_group{$g1} }));
#		printf("Range of $g2: [%u-%u]\n", min(@{ $ndx_group{$g2} }), max(@{ $ndx_group{$g2} }));
		say "$g1:";
		p $ndx_group{$g1};#, array_max => scalar @{ $ndx{$g1} };
		say "$g2:";
		p $ndx_group{$g2};#, array_max => scalar @{ $ndx{$g2} };
		my @intersection = $lc->get_intersection;
		printf $log ("$g1i/$g1 vs $g2i/$g2: %u atoms in common.\n", scalar @intersection);
		next if scalar @intersection > 0; # this will fail anyway
		my $stem = "$g1.$g2";
		say "\$g1 = $g1";
		say "\$g2 = $g2";
		$stem =~ s/[!@#\$\%^&*\(\)\{\}\[\]\<\>,\/'"\-\h;\+\=]+/_/g; # annoying chars
		my $ang  = "hbond/hbond.$stem.ang.xvg";
		my $dan  = "hbond/hbond.$stem.dan.xvg";
		my $dist = "hbond/hbond.$stem.dist.xvg";
		my $num  = "hbond/hbond.$stem.num.xvg";
		unlink 'hbond.ndx' if -f 'hbond.ndx';
		job("printf \"$g1i\\n$g2i\\n\" | $input{gmx} hbond -s md.tpr -f md.xtc -tu ps -num $num -dan $dan -dist $dist -ang $ang", 0, $ang, $dan, $dist, $num);
		$g2i++;
	}
}
=my $hb_protein = 'hb_protein_to_itself.xvg';
job("printf \"1\\n1\\n\" | $input{gmx} hbond -s md.tpr -f md.xtc -tu ns -num $hb_protein", $hb_protein);
my $hb_solvent = 'hb_protein_to_solvent.xvg';
job("printf \"1\\n12\\n\" | $input{gmx} hbond -s md.tpr -f md.xtc -tu ns -num $hb_solvent", $hb_solvent);
