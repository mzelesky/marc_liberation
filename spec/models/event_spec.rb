require 'rails_helper'
require 'fileutils'

RSpec.describe Event, type: :model do

  before(:all) do
    system 'rake db:seed'
    bibs = './spec/fixtures/sample_bib_ids.txt'
    10.times { dump_test_bib_ids(bibs) }
    10.times { test_events('HOLDING_IDS') }
    10.times { test_events('CHANGED_RECORDS') }
    5.times { test_events('ALL_RECORDS') }
  end

  after(:all) do
    Event.destroy_all
    DumpFileType.destroy_all
    Resque.redis.del "queue:default"
  end

  describe 'ALL_RECORDS dump' do
    it 'removes stale dump events after completing dump' do
      Dump.full_bib_dump
      expect(dump_count('BIB_IDS')).to eq 8
      expect(dump_count('HOLDING_IDS')).to eq 8
      expect(dump_count('CHANGED_RECORDS')).to eq 8
      expect(dump_count('ALL_RECORDS')).to eq 3
    end

    it 'creates unique dumpfile path names for each dump' do
      dump = Dump.full_bib_dump
      paths = dump.dump_files.collect { |df| df.path }
      expect(paths).to eq paths.uniq
    end
  end

  def dump_test_bib_ids(bibs)
    dump = nil
    Event.record do |event|
      dump = Dump.create(dump_type: DumpType.find_by(constant: 'BIB_IDS'))
      dump.event = event
      dump_file = DumpFile.create(dump: dump, dump_file_type: DumpFileType.find_by(constant: 'BIB_IDS'))
      FileUtils.cp bibs, dump_file.path
      dump_file.save
      dump_file.zip
      dump.dump_files << dump_file
      dump.save
    end
    dump
  end

  def test_events(type)
    dump = nil
    Event.record do |event|
      dump = Dump.create(dump_type: DumpType.find_by(constant: type))
      dump.event = event
      dump.save
    end
    dump
  end

  def dump_count(type)
    Dump.where(dump_type: DumpType.find_by(constant: type)).count
  end

end
