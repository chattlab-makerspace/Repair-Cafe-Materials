#!/usr/bin/env ruby

require 'json'
require 'csv'

class HandwrittenTextExtractor
  # Baseline coordinates for RepairMonitor text position
  BASELINE_REPAIRMONITOR = { x: 0.5823, y: 0.0683 }.freeze
  
  # Define field mappings based on position coordinates
  FIELD_MAPPINGS = {
    name: { x_range: 0.2..0.5, y_range: 0.07..0.18 },
    date: { x_range: 0.5..0.7, y_range: 0.1..0.18 },
    reference: { x_range: 0.7..1, y_range: 0.1..0.18 },
    product: { x_range: 0.3..1, y_range: 0.21..0.25 },
    brand: { x_range: 0.15..1, y_range: 0.25..0.29 },
    year: { x_range: 0.2..1, y_range: 0.29..0.32 },
    model: { x_range: 0.3..1, y_range: 0.32..0.35 },
    problem_description: { x_range: 0.4..1, y_range: 0.35..0.4 },
    repairer: { x_range: 0.2..1, y_range: 0.4..0.45 },
    defect_found: { x_range: 0.2..1, y_range: 0.45..0.47 },
    been_repaired_yes: { x_range: 0.25..0.40, y_range: 0.48..0.5 },
    been_repaired_partial: { x_range: 0.40..0.50, y_range: 0.48..0.5 },
    been_repaired_no: { x_range: 0.60..0.70, y_range: 0.48..0.5 },
    repair_steps: { x_range: 0..1, y_range: 0.5..0.57 },
    partial_advice: { x_range: 0..1, y_range: 0.57..0.65 },
    why_not_repaired: { x_range: 0..1, y_range: 0.65..0.69 },
    info_used_yes: { x_range: 0.20..0.40, y_range: 0.72..0.77 },
    info_used_no_find: { x_range: 0.40..0.60, y_range: 0.72..0.77 },
    info_used_no_look: { x_range: 0.60..75, y_range: 0.72..0.77 },
    info_from_manufacturer: { x_range: 0.20..0.50, y_range: 0.77..0.79 },
    info_from_repairer: { x_range: 0.50..0.70, y_range: 0.77..0.79 },
    info_source: { x_range: 0..1, y_range: 0.79..0.85 },
    suggestions: { x_range: 0..1, y_range: 0.85..0.95 },
    other: { x_range: 0.0..1.0, y_range: 0.0..1.0 }
  }.freeze

  def initialize(file_path)
    @file_path = file_path
    @data = nil
    @pages = {}
    @page_offsets = {}
  end

  def parse_file
    puts "Reading file: #{@file_path}"
    
    begin
      file_content = File.read(@file_path)
      @data = JSON.parse(file_content)
      puts "Successfully parsed JSON file"
    rescue JSON::ParserError => e
      puts "Error parsing JSON: #{e.message}"
      return false
    rescue => e
      puts "Error reading file: #{e.message}"
      return false
    end

    extract_handwritten_text_by_page
    true
  end

  def extract_handwritten_text_by_page
    return unless @data && @data['Blocks']

    @data['Blocks'].each do |block|
      next unless block['BlockType'] == 'WORD' && block['TextType'] == 'HANDWRITING'
      
      page_number = block['Page'] || 1
      
      @pages[page_number] ||= []
      bbox = block['Geometry']['BoundingBox']
      @pages[page_number] << {
        text: block['Text'],
        confidence: block['Confidence'],
        geometry: {
          'Left' => bbox['Left'],
          'Top' => bbox['Top'],
          'Width' => bbox['Width'],
          'Height' => bbox['Height'],
          'CenterX' => bbox['Left'] + (bbox['Width'] / 2.0),
          'CenterY' => bbox['Top'] + (bbox['Height'] / 2.0)
        }
      }
    end

    puts "Found handwritten text on #{@pages.keys.length} page(s)"
    @pages.each do |page, blocks|
      puts "  Page #{page}: #{blocks.length} handwritten text blocks"
    end
  end

  def calculate_offsets_from_repairmonitor(page_number)
    return false unless @data && @data['Blocks']

    # Find all RepairMonitor text instances in printed blocks for this specific page
    repairmonitor_instances = []
    
    @data['Blocks'].each do |block|
      next unless block['BlockType'] == 'WORD' && block['TextType'] == 'PRINTED'
      next unless (block['Page'] || 1) == page_number
      
      if block['Text']&.downcase&.include?('repairmonitor')
        bbox = block['Geometry']['BoundingBox']
        actual_x = bbox['Left']
        actual_y = bbox['Top']
        
        repairmonitor_instances << {
          x: actual_x,
          y: actual_y,
          text: block['Text']
        }
      end
    end
    
    # If no RepairMonitor found, skip page
    if repairmonitor_instances.empty?
      puts "Page #{page_number}: RepairMonitor text not found, skipping page"
      return false
    end
    
    # Find the instance closest to the baseline
    closest_instance = repairmonitor_instances.min_by do |instance|
      distance = Math.sqrt(
        (instance[:x] - BASELINE_REPAIRMONITOR[:x])**2 + 
        (instance[:y] - BASELINE_REPAIRMONITOR[:y])**2
      )
      distance
    end
    
    # Calculate offsets from baseline using the closest instance
    x_offset = closest_instance[:x] - BASELINE_REPAIRMONITOR[:x]
    y_offset = closest_instance[:y] - BASELINE_REPAIRMONITOR[:y]
    
    @page_offsets[page_number] = { x: x_offset, y: y_offset }
    
    puts "Page #{page_number}: Found #{repairmonitor_instances.length} RepairMonitor instance(s)"
    puts "Page #{page_number}: Selected closest at top/left: x=#{closest_instance[:x].round(4)}, y=#{closest_instance[:y].round(4)}"
    puts "Page #{page_number}: Calculated offsets: x=#{x_offset.round(4)}, y=#{y_offset.round(4)}"
    return true
  end

  def classify_text_by_position(handwritten_blocks, page_number)
    classified_text = {}
    
    handwritten_blocks.each do |block|
      x_position = block[:geometry]['CenterX']
      y_position = block[:geometry]['CenterY']
      text = block[:text]
      
      field_type = determine_field_type(x_position, y_position, page_number)
      
      if classified_text[field_type]
        classified_text[field_type] += " #{text}"
      else
        classified_text[field_type] = text
      end
    end
    
    classified_text
  end

  def determine_field_type(x_pos, y_pos, page_number)
    # Get page-specific offsets
    page_offset = @page_offsets[page_number] || { x: 0.0, y: 0.0 }
    
    # Apply offsets to adjust coordinates based on RepairMonitor position
    adjusted_x = x_pos - page_offset[:x]
    adjusted_y = y_pos - page_offset[:y]
    
    # Check each field type's position ranges with adjusted coordinates
    FIELD_MAPPINGS.each do |field, config|
      if config[:x_range].cover?(adjusted_x) && config[:y_range].cover?(adjusted_y)
        return field
      end
    end
    
    # Default to :other if no specific field matches
    :other
  end

  def output_results
    return unless @pages.any?

    @pages.each do |page_number, handwritten_blocks|
      # Skip pages where RepairMonitor is not found
      next unless calculate_offsets_from_repairmonitor(page_number)
      
      puts "\n" + "="*60
      puts "PAGE #{page_number} - EXTRACTED HANDWRITTEN TEXT"
      puts "="*60

      classified = classify_text_by_position(handwritten_blocks, page_number)
      
      # Output in a structured format
      classified.each do |field, value|
        output_field(field.capitalize, value)
      end
      
      # Output any unclassified text
      if classified[:other]
        output_field("Other", classified[:other])
      end

      puts "\n" + "-"*40
      puts "RAW HANDWRITTEN TEXT BLOCKS"
      puts "-"*40
      
      handwritten_blocks.each_with_index do |block, index|
        x_pos = block[:geometry]['CenterX'].round(3)
        y_pos = block[:geometry]['CenterY'].round(3)
        confidence = block[:confidence].round(1)
        puts "#{index + 1}. '#{block[:text]}' (confidence: #{confidence}%, center: #{x_pos}, #{y_pos})"
      end
    end
  end

  def run
    if parse_file
      output_results
      output_csv
    else
      puts "Failed to process file"
      exit 1
    end
  end

  def output_csv
    return unless @pages.any?

    puts "\n" + "="*60
    puts "CSV OUTPUT"
    puts "="*60

    # Define CSV headers
    headers = ['file', 'page', *FIELD_MAPPINGS.keys.map(&:to_s)]

    # Use CSV gem to generate output
    csv_output = CSV.generate do |csv|
      # Add header row
      csv << headers
      
      # Add data rows for each page (only pages with RepairMonitor)
      @pages.each do |page_number, handwritten_blocks|
        # Skip pages where RepairMonitor is not found
        next unless @page_offsets.key?(page_number)
        
        classified = classify_text_by_position(handwritten_blocks, page_number)
        
        basename = File.basename(@file_path)

        # Create row data
        row = [basename, page_number.to_s]
        headers[2..-1].each do |field|
          value = classified[field.to_sym]
          row << (value && !value.strip.empty? ? value.strip : "")
        end
        
        csv << row
      end
    end
    
    puts csv_output
  end

  private

  def output_field(label, value)
    if value && !value.strip.empty?
      puts "#{label}: #{value.strip}"
    end
  end
end

# Main execution
if ARGV.empty?
  puts "Usage: ruby #{$0} <path_to_json_file>"
  puts "\nExample: ruby #{$0} document.json"
  exit 1
end

file_path = ARGV[0]

unless File.exist?(file_path)
  puts "Error: File '#{file_path}' not found"
  exit 1
end

extractor = HandwrittenTextExtractor.new(file_path)
extractor.run