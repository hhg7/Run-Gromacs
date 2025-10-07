#!/usr/bin/env perl

use 5.042;
no source::encoding;
use warnings FATAL => 'all';
use autodie ':default';
use Devel::Confess 'color';
use Capture::Tiny 'capture';
use DDP {output => 'STDOUT', array_max => 10, show_memsize => 1};
use Term::ANSIColor;
use Getopt::ArgParse;
# this is kind of like my nextFlow, as I understand it

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

sub job ($cmd, @product_files) {
	say 'The command is ' . colored(['blue on_bright_red'], $cmd);
	say 'And the products are:';
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
		p %r;
		return \%r;
	}
	($hash{stdout}, $hash{stderr}, $hash{'exit'}) = capture {
		system( $cmd );
	};
	$r{done} = 'now';
	p %r;
	p(%r, output => $log);
	if ($exit != 0) {
		p %r;
		die "$cmd failed"
	}
	return \%r;
}
#------------
my $processed_gro = $input{pdb};
   $processed_gro =~ s/pdb$/gro/;
my $topol = 'topol.top';
# generate topology
my $ignore_H = '';
if ($args->ignore_H) {
	$ignore_H = '-ignh';
}
my $r = job("$input{gmx} pdb2gmx -f $input{pdb} $ignore_H -o $processed_gro -water $input{water} -ff $input{force_field}", $processed_gro, $topol);
p $r;
#------------
# Defining the simulation box
#------------
my $new_box = $processed_gro;
$new_box =~ s/gro$/newbox.gro/;
$r = job("$input{gmx} editconf -f $processed_gro -o $new_box -c -d 1.0 -bt dodecahedron", $new_box);
p $r;
#------------
# fill the box with water
#------------
my $solv = $new_box;
$solv =~ s/newbox.gro$/solv.gro/;
$r = job("$input{gmx} solvate -cp $new_box -cs spc216.gro -o $solv -p $topol", $solv);
p $r;
#------------
# prepare input for gmx genion
#------------
#.mdp: "molecular dynamics parameter" file that specifies all relevant settings for performing a calculation or simulation
my $ions_mdp = 'ions.mdp';
$r = job("touch $ions_mdp", $ions_mdp);
p $r;
my $ions_tpr = 'ions.tpr';
$r = job("$input{gmx} grompp -f $ions_mdp -c $solv -p topol.top -o $ions_tpr", $ions_tpr);
p $r;
my $solv_ions = $solv;
$solv_ions =~ s/solv\.gro$/solv_ions.gro/;
unlink $solv_ions if -f $solv_ions;
$r = job("printf \"SOL\\n\" | $input{gmx} genion -s $ions_tpr -o $solv_ions -conc 0.15 -p $topol -pname NA -nname CL -neutral", $solv_ions);
p $r;
#--------------
# energy minimization
#--------------
my $em_tpr = 'em.tpr'; # .tpr: a binary run input file that combines coordinates, topology, all associated force field parameters, and all input settings defined in the .mdp file
$r = job( "$input{gmx} grompp -f $input{emin} -c $solv_ions -p $topol -o $em_tpr", $em_tpr);
my ($em_log, $em_gro, $em_trr, $em_edr) = ('em.log', 'em.gro', 'em.trr', 'em.edr');
p $r;
say '---------------';
say '--Now running energy minimization';
say '---------------';
$r = job( "$input{gmx} mdrun -v -deffnm em", $em_log, $em_gro, $em_trr, $em_edr);
#------------
# Equilibration run - temperature
# first phase is conducted under an NVT ensemble (constant Number of particles, Volume, and Temperature)
#--------------
my $nvt_tpr = 'nvt.tpr';
$r = job("$input{gmx} grompp -f $input{nvt} -c $em_gro -r $em_gro -p $topol -o $nvt_tpr", $nvt_tpr);
my ($nvt_log, $nvt_edr, $nvt_gro, $nvt_cpt) = ('nvt.log', 'nvt.edr', 'nvt.gro', 'nvt.cpt');
# checkpoint file is "cpt"
# comment out if debugging, it's slow
$r = job("$input{gmx} mdrun -v -deffnm nvt", $nvt_log, $nvt_edr, $nvt_gro, $nvt_cpt);
#------------
# Equilibration run - pressure
# Number of particles, Pressure, and Temperature are held constant (isothermal/isobaric)
#------------
my $npt_tpr = 'npt.tpr';
$r = job("$input{gmx} grompp -f $input{npt} -c $nvt_gro -r $nvt_gro -t $nvt_cpt -p $topol -o $npt_tpr", $npt_tpr);
my ($npt_edr, $npt_gro, $npt_cpt) = ('npt.edr', 'npt.gro', 'npt.cpt');
$r = job("$input{gmx} mdrun -v -deffnm npt", $npt_edr, $npt_gro, $npt_cpt);
my $chain_ndx = 'npt.chains.ndx';
$r = job("printf \"splitch 1\\nq\\n\" | $input{gmx} make_ndx -f nvt.tpr -o $chain_ndx", $chain_ndx);
# view the output from above thus: gmx check -n npt.chains.ndx
#------------
# Production run
#------------
unless ($args->production_input_file) {
	close $log;
	say 'no production input file was specified, so finishing now...';
	say 'wrote ' . colored(['gray on_black'], $args->log_file);
	exit;
}
my $md_tpr = 'md.tpr';
$r = job("$input{gmx} grompp -f $input{production_input_file} -c $npt_gro -t $npt_cpt -p $topol -o $md_tpr", $md_tpr);
my ($md_log, $md_edr, $md_gro, $md_xtc, $md_prev_cpt) = ('md.log', 'md.edr', 'md.gro', 'md.xtc', 'md_prev.cpt');
$r = job("$input{gmx} mdrun -v -deffnm md", $md_log, $md_edr, $md_gro, $md_xtc, $md_prev_cpt);
#------------
# Analysis
#------------
my $md_center = 'md_center.xtc';
job("printf \"1\\n1\\n\" | $input{gmx} trjconv -s $md_tpr -f $md_xtc -o $md_center -center -pbc mol", $md_center);

job("printf \"1\\n1\\n\" | $input{gmx} mindist -s md.tpr -f $md_center -pi -od mindist.xvg", 'mindist.xvg');
my $rmsd_xray = 'rmsd_xray.xvg';
job("printf \"4\\n1\\n\" | $input{gmx} rms -s $em_tpr -f $md_center -o $rmsd_xray -tu ns -xvg none", $rmsd_xray);

# Measure compactness with radius of gyration
my $gyrate_xvg = 'gyrate.xvg';
job("echo 1 | $input{gmx} gyrate -f md_center.xtc -s md.tpr -o $gyrate_xvg -xvg none", $gyrate_xvg);
close $log;
say 'wrote ' . colored(['gray on_black'], $args->log_file);
