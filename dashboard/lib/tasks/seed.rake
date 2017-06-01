require "csv"

namespace :seed do
  verbose false

  levels_to_load = nil

  task videos: :environment do
    Video.setup
  end

  task concepts: :environment do
    Concept.setup
  end

  task games: :environment do
    Game.setup
  end

  SCRIPTS_GLOB = Dir.glob('config/scripts/**/*.script').sort.flatten
  UI_TEST_SCRIPTS = [
    '20-hour',
    'algebra',
    'allthehiddenthings',
    'alltheplcthings',
    'allthethings',
    'artist',
    'course1',
    'course2',
    'course3',
    'course4',
    'events',
    'flappy',
    'frozen',
    'hourofcode',
    'infinity',
    'mc',
    'minecraft',
    'playlab',
    'starwars',
    'starwarsblocks',
    'step',
  ].map {|script| "config/scripts/#{script}.script"}
  SEEDED = 'config/scripts/.seeded'

  file SEEDED => [SCRIPTS_GLOB, :environment].flatten do
    update_scripts
  end

  def update_scripts(opts = {})
    # optionally, only process modified scripts to speed up seed time
    scripts_seeded_mtime = (opts[:incremental] && File.exist?(SEEDED)) ?
      File.mtime(SEEDED) : Time.at(0)
    touch SEEDED # touch seeded "early" to reduce race conditions
    script_files = opts[:ui_test] ? UI_TEST_SCRIPTS : SCRIPTS_GLOB
    begin
      custom_scripts = script_files.select {|script| File.mtime(script) > scripts_seeded_mtime}
      LevelLoader.update_unplugged if File.mtime('config/locales/unplugged.en.yml') > scripts_seeded_mtime
      _, custom_i18n = Script.setup(custom_scripts)
      Script.merge_and_write_i18n(custom_i18n)
    rescue
      rm SEEDED # if we failed to do any of that stuff we didn't seed anything, did we
      raise
    end
  end

  SCRIPTS_DEPENDENCIES = [:environment, :games, :custom_levels, :dsls]
  task scripts: SCRIPTS_DEPENDENCIES do
    update_scripts(incremental: false)
  end

  task scripts_incremental: SCRIPTS_DEPENDENCIES do
    update_scripts(incremental: true)
  end

  UI_TEST_SCRIPTS_DEPENDENCIES = [:environment, :games, :ui_test_custom_levels, :ui_test_dsls]
  task scripts_ui_tests: UI_TEST_SCRIPTS_DEPENDENCIES do
    update_scripts(ui_test: true)
  end

  task courses: :environment do
    Dir.glob(Course.file_path('**')).sort.map do |path|
      Course.load_from_path(path)
    end
  end

  # detect changes to dsldefined level files
  # LevelGroup must be last here so that LevelGroups are seeded after all levels that they can contain
  DSL_TYPES = %w(TextMatch ContractMatch External Match Multi EvaluationMulti LevelGroup)
  DSLS_GLOB = DSL_TYPES.map {|x| Dir.glob("config/scripts/**/*.#{x.underscore}*").sort}.flatten
  file 'config/scripts/.dsls_seeded' => DSLS_GLOB do |t|
    Rake::Task['seed:dsls'].invoke
    touch t.name
  end

  # explicit execution of "seed:dsls"
  task dsls: :environment do
    load_dsl_defined
  end

  task ui_test_dsls: [:environment, :ui_test_levels] do
    load_dsl_defined(levels_to_load)
  end

  def load_dsl_defined(levels_to_load=nil)
    DSLDefined.transaction do
      i18n_strings = {}
      # Parse each .[dsl] file and setup its model.
      DSLS_GLOB.each do |filename|
        if levels_to_load && !levels_to_load.include?(filename)
          next
        end
        dsl_class = DSL_TYPES.detect {|type| filename.include?(".#{type.underscore}")}.try(:constantize)
        begin
          data, i18n = dsl_class.parse_file(filename)
          dsl_class.setup data
          i18n_strings.deep_merge! i18n
        rescue Exception
          puts "Error parsing #{filename}"
          raise
        end
      end
      # Rewrite autogenerated 'dsls.en.yml' i18n file with new master-copy English strings
      i18n_warning = "# Autogenerated English-language level-definition locale file. Do not edit by hand or commit to version control.\n"
      File.write('config/locales/dsls.en.yml', i18n_warning + i18n_strings.deep_sort.to_yaml(line_width: -1))
    end
  end

  task import_custom_levels: :environment do
    LevelLoader.load_custom_levels
  end

  # Generate the database entry from the custom levels json file
  task custom_levels: :environment do
    LevelLoader.load_custom_levels
  end

  task ui_test_custom_levels: [:environment, :ui_test_levels] do
    LevelLoader.load_custom_levels(levels_to_load)
  end

  task ui_test_levels: :environment do
    levels_to_load ||= LevelLoader.levels_used_in_scripts(UI_TEST_SCRIPTS)
  end

  task callouts: :environment do
    Callout.transaction do
      Callout.reset_db
      # TODO: If the id of the callout is important, specify it in the tsv
      # preferably the id of the callout is not important ;)
      Callout.find_or_create_all_from_tsv!('config/callouts.tsv')
    end
  end

  task school_districts: :environment do
    # use a much smaller dataset in environments that reseed data frequently.
    school_districts_tsv = CDO.stub_school_data ? 'test/fixtures/school_districts.tsv' : 'config/school_districts.tsv'
    expected_count = `wc -l #{school_districts_tsv}`.to_i - 1
    raise "#{school_districts_tsv} contains no data" unless expected_count > 0

    SchoolDistrict.transaction do
      # It takes approximately 30 seconds to seed config/school_districts.tsv.
      # Skip seeding if the data is already present. Note that this logic may need
      # to be updated once we incorporate data from future survey years.
      if SchoolDistrict.count < expected_count
        # Since other models (e.g. Pd::Enrollment) have a foreign key dependency
        # on SchoolDistrict, don't reset_db first.  (Callout, above, does that.)
        puts "seeding school districts (#{expected_count} rows)"
        SchoolDistrict.find_or_create_all_from_tsv(school_districts_tsv)
      end
    end
  end

  task schools: :environment do
    # use a much smaller dataset in environments that reseed data frequently.
    schools_tsv = CDO.stub_school_data ? 'test/fixtures/schools.tsv' : 'config/schools.tsv'
    expected_count = `wc -l #{schools_tsv}`.to_i - 1
    raise "#{schools_tsv} contains no data" unless expected_count > 0

    School.transaction do
      # It takes approximately 4 minutes to seed config/schools.tsv.
      # Skip seeding if the data is already present. Note that this logic may need
      # to be updated once we incorporate data from future survey years.
      if School.count < expected_count
        # Since other models will have a foreign key dependency
        # on School, don't reset_db first.  (Callout, above, does that.)
        puts "seeding schools (#{expected_count} rows)"
        School.find_or_create_all_from_tsv(schools_tsv)
      end
    end
  end

  task regional_partners: :environment do
    RegionalPartner.transaction do
      RegionalPartner.find_or_create_all_from_tsv('config/regional_partners.tsv')
    end
  end

  task regional_partners_school_districts: :environment do
    seed_regional_partners_school_districts(false)
  end

  task force_regional_partners_school_districts: :environment do
    seed_regional_partners_school_districts(true)
  end

  def seed_regional_partners_school_districts(force)
    # use a much smaller dataset in environments that reseed data frequently.
    mapping_tsv = CDO.stub_school_data ?
        'test/fixtures/regional_partners_school_districts.tsv' :
        'config/regional_partners_school_districts.tsv'

    expected_count = `grep -v 'NO PARTNER' #{mapping_tsv} | wc -l`.to_i - 1
    raise "#{mapping_tsv} contains no data" unless expected_count > 0
    RegionalPartnersSchoolDistrict.transaction do
      if (RegionalPartnersSchoolDistrict.count < expected_count) || force
        # This step can take up to 1 minute to complete when not using stubbed data.
        RegionalPartnersSchoolDistrict.find_or_create_all_from_tsv(mapping_tsv)
      end
    end
  end

  MAX_LEVEL_SOURCES = 10_000
  desc "calculate solutions (ideal_level_source) for levels based on most popular correct solutions (very slow)"
  task ideal_solutions: :environment do
    require 'benchmark'
    Level.where_we_want_to_calculate_ideal_level_source.each do |level|
      next if level.try(:free_play?)
      puts "Level #{level.id}"
      level_sources_count = level.level_sources.count
      if level_sources_count > MAX_LEVEL_SOURCES
        puts "...skipped, too many possible solutions"
      else
        times = Benchmark.measure {level.calculate_ideal_level_source_id}
        puts "... analyzed #{level_sources_count} in #{times.real.round(2)}s"
      end
    end
  end

  task :import_users, [:file] => :environment do |_t, args|
    CSV.read(args[:file], {col_sep: "\t", headers: true}).each do |row|
      User.create!(
        provider: User::PROVIDER_MANUAL,
        name: row['Name'],
        username: row['Username'],
        password: row['Password'],
        password_confirmation: row['Password'],
        birthday: row['Birthday'].blank? ? nil : Date.parse(row['Birthday'])
      )
    end
  end

  task secret_words: :environment do
    SecretWord.setup
  end

  task secret_pictures: :environment do
    SecretPicture.setup
  end

  desc "seed all dashboard data"
  task all: [:videos, :concepts, :scripts, :callouts, :school_districts, :schools, :regional_partners, :regional_partners_school_districts, :secret_words, :secret_pictures, :courses]
  task :ui_test do
    [
      :videos,
      :concepts,
      :scripts_ui_tests,
      :callouts,
      :school_districts,
      :schools,
      :regional_partners,
      :regional_partners_school_districts,
      :secret_words,
      :secret_pictures,
    ].map do |to_seed|
      puts "[#{Time.now}] Seeding #{to_seed}"
      Rake::Task["seed:#{to_seed}"].invoke
    end
  end
  desc "seed all dashboard data that has changed since last seed"
  task incremental: [:videos, :concepts, :scripts_incremental, :callouts, :school_districts, :schools, :regional_partners, :regional_partners_school_districts, :secret_words, :secret_pictures, :courses]

  desc "seed only dashboard data required for tests"
  task test: [:videos, :games, :concepts, :secret_words, :secret_pictures, :school_districts, :schools, :regional_partners, :regional_partners_school_districts]
end
