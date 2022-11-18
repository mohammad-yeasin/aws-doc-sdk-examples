# frozen_string_literal: true

# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

# Purpose
#
# Shows how to use the Amazon Relational Database Service (Amazon RDS) Data Service to
# interact with an Amazon Aurora Serverless database.

require 'logger'
require_relative('report')
require_relative 'helpers/errors'
require_relative 'models/item'
require 'sequel'
require 'multi_json'
require 'erb'
# from botocore.exceptions import ClientError

# Wraps issues commands directly to the Amazon RDS Data Service, including SQL statements.
class DBWrapper
  # @param config [List]
  # @param rds_client [AWS::RDS::Client] An Amazon RDS Data Service client.
  def initialize(config, rds_client)
    @cluster = config['resource_arn']
    @secret = config['secret_arn']
    @db_name = config['database']
    @table_name = config['table_name']
    @rds_client = rds_client
    @model = Sequel::Database.new
    @logger = Logger.new($stdout)
  end

  def _format_sql(sql)
    sql = sql.delete '"'
    sql.downcase
  end

  def true?(obj)
    obj.to_s.downcase == "true"
  end

  # Converts larger ExecuteStatementResponse into simplified Ruby object
  # @param results [Aws::RDSDataService::Types::ExecuteStatementResponse]
  # @return output [List] A list of items, represented as hashes
  def _parse_work_items(results)
    json = MultiJson.load(results)
    output = []
    json.each do |x|
      name = x["username"]
      id = x["work_item_id"]
      x["name"] = name
      x["id"] = id
      output.append(x)
    end
    # @logger.info(MultiJson.dump(output))
    MultiJson.dump(output)
  end

  # Runs a SQL statement and associated parameters using the Amazon RDS Data Service.
  # @param sql [String] The SQL statement to run against the database.
  # @return [Aws::RDSDataService::Types::ExecuteStatementResponse,
  #   RDSResourceError, RDSClientError, StandardError] Output of the request to
  #   run a SQL statement against the database, or error class.
  def _run_statement(sql)
    run_args = {
      'database': @db_name,
      'resource_arn': @cluster,
      'secret_arn': @secret,
      'sql': sql,
      'format_records_as': 'JSON'
    }
    @logger.info("Ran statement on #{@db_name}.")
    @rds_client.execute_statement(**run_args)
  rescue Aws::Errors::ServiceError => e
    if e.response['Error']['Code'] == 'BadRequestException' &&
       e.response['Error']['Message'].include?('Communications link failure')
      raise RDSResourceError(
        'The Aurora Data Service is not ready, probably because it entered '\
        'pause mode after a period of inactivity. Wait a minute for '\
        'your cluster to resume and try your request again.'
      )
    else
      @logger.error("Run statement on #{@db_name} failed within AWS")
      raise RDSClientError(e)
    end
  rescue StandardError => e
    @logger.error("There was an error outside of AWS:#{e}")
    raise
  end

  # Gets database table name
  def get_table_name
    sql = @model.from(:work_items).sql
    sql = 'SHOW TABLES'
    sql = _format_sql(sql)
    @logger.info("Prepared GET query: #{sql}")
    response = _run_statement(sql)
    response.formatted_records.delete_prefix('"').delete_suffix('"')
  end

  # Gets work items from the database.
  # @param item_id [String] The Item ID to fetch. Returns all items if nil. Default: nil.
  # @param include_archived [Boolean] If true, include archived items. Default: false
  # @return [Array] The hashed records from RDS which represent work items.
  def get_work_items(item_id=nil, include_archived=false)
    sql = @model.select(:work_item_id, :description, :guide, :status, :username, :archive).from(:work_items)
    sql = sql.where(archive: true?(include_archived))
    sql = sql.where(work_item_id: item_id.to_i) if item_id
    sql = _format_sql(sql.sql)
    @logger.info("Prepared GET query: #{sql}")
    results = _run_statement(sql)
    body = results.formatted_records.delete_prefix('"').delete_suffix('"')
    response = _parse_work_items(body)
    json = MultiJson.load(response)
    @logger.info("Received GET response: #{json}")
    json
  end

  # Adds a work item to the database.
  # @param data [Hash] A Ruby object containing data fields
  # @return: The generated ID of the new work item.
  def add_work_item(data)
    sql = @model.from(:work_items).insert_sql(
      description: data["description"],
      guide: data["guide"],
      status: data["status"],
      username: data["username"]
    )
    sql = _format_sql(sql)
    @logger.info("Prepared POST query: #{sql}")
    response = _run_statement(sql)
    id = response["generated_fields"][0]['long_value']
    @logger.info("Successfully created work_item_id: #{id}")
    id
  end

  # Archives a work item.
  # @param item_id [String] The ID of the work item to archive.
  # @returns [Boolean] If updated_records is 1, return true; else, return false.
  def archive_work_item(item_id)
    sql = @model.from(:work_items).where(work_item_id: item_id).update_sql(archive: 1) # 1 is true, 0 is false
    sql = _format_sql(sql)
    @logger.info("Prepared PUT query: #{sql}")
    response = _run_statement(sql)
    @logger.info("Successfully archived item_id: #{item_id}")
    response.number_of_records_updated == 1
  end
end
