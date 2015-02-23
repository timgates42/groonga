require "scan_info_search_index"

module Groonga
  class ScanInfoData
    attr_accessor :start
    attr_accessor :end
    attr_accessor :op
    attr_accessor :logical_op
    attr_accessor :query
    attr_accessor :args
    attr_accessor :search_indexes
    attr_accessor :flags
    attr_accessor :max_interval
    attr_accessor :similarity_threshold
    attr_accessor :scorer
    attr_accessor :scorer_args_expr
    attr_accessor :scorer_args_expr_offset
    def initialize(start)
      @start = start
      @end = 0
      @op = Operator::NOP
      @logical_op = Operator::OR
      @query = nil
      @args = []
      @search_indexes = []
      @flags = ScanInfo::Flags::PUSH
      @max_interval = nil
      @similarity_threshold = nil
      @scorer = nil
      @scorer_args_expr = nil
      @scorer_args_expr_offset = nil
    end

    def match_resolve_index
      if near_search?
        match_near_resolve_index
      elsif similar_search?
        match_similar_resolve_index
      else
        match_generic_resolve_index
      end
    end

    def call_relational_resolve_indexes
      # better index resolving framework for functions should be implemented
      @args.each do |arg|
        call_relational_resolve_index(arg)
      end
    end

    private
    def near_search?
      (@op == Operator::NEAR or @op == Operator::NEAR2) and @args.size == 3
    end

    def match_near_resolve_index
      arg = @args[0]
      case arg
      when Expression
        match_resolve_index_expression(arg)
      when Accessor
        match_resolve_index_accessor(arg)
      when Object
        match_resolve_index_db_obj(arg)
      else
        message =
          "The first argument of NEAR/NEAR2 must be Expression, Accessor or Object: #{arg.class}"
        raise ErrorMessage, message
      end

      self.query = @args[1]
      self.max_interval = @args[2].value
    end

    def similar_search?
      @op == Operator::SIMILAR and @args.size == 3
    end

    def match_similar_resolve_index
      arg = @args[0]
      case arg
      when Expression
        match_resolve_index_expression(arg)
      when Accessor
        match_resolve_index_accessor(arg)
      when Object
        match_resolve_index_db_obj(arg)
      else
        message =
          "The first argument of SIMILAR must be Expression, Accessor or Object: #{arg.class}"
        raise ErrorMesesage, message
      end

      self.query = @args[1]
      self.similarity_threshold = @args[2].value
    end

    def match_generic_resolve_index
      @args.each do |arg|
        case arg
        when Expression
          match_resolve_index_expression(arg)
        when Accessor
          match_resolve_index_accessor(arg)
        when Object
          match_resolve_index_db_obj(arg)
        else
          self.query = arg
        end
      end
    end

    def match_resolve_index_expression(expression)
      codes = expression.codes
      n_codes = codes.size
      i = 0
      while i < n_codes
        i = match_resolve_index_expression_codes(expression, codes, i, n_codes)
      end
    end

    def match_resolve_index_expression_codes(expression, codes, i, n_codes)
      code = codes[i]
      value = code.value
      case value
      when Accessor
        match_resolve_index_expression_accessor(code)
      when FixedSizeColumn, VariableSizeColumn
        match_resolve_index_expression_data_column(code)
      when IndexColumn
        section_id = 0
        rest_n_codes = n_codes - i
        if rest_n_codes >= 2 and
          codes[i + 1].value.is_a?(Bulk) and
          (codes[i + 1].value.domain == ID::UINT32 or
           codes[i + 1].value.domain == ID::INT32) and
          codes[i + 2].op == Operator::GET_MEMBER
          section_id = codes[i + 1].value.value + 1
          code = codes[i + 2]
          i += 2
        end
        put_search_index(value, section_id, code.weight)
      when Procedure
        unless value.scorer?
          message = "procedure must be scorer: #{scorer.name}>"
          raise ErrorMessage, message
        end
        @scorer = value
        rest_n_codes = n_codes - i
        if rest_n_codes == 0
          message = "match target is required as an argument: <#{scorer.name}>"
          raise ErrorMessage, message
        end
        i = match_resolve_index_expression_codes(expression, codes, i + 1,
                                                 n_codes)
        unless codes[i].op == Operator::CALL
          @scorer_args_expr = expression
          @scorer_args_expr_offset = i
          until codes[i].op == Operator::CALL
            i += 1
          end
        end
      when Table
        raise ErrorMessage, "invalid match target: <#{value.name}>"
      end
      i + 1
    end

    def match_resolve_index_expression_accessor(expr_code)
      accessor = expr_code.value
      self.flags |= ScanInfo::Flags::ACCESSOR
      index_info = accessor.find_index(op)
      return if index_info.nil?

      section_id = index_info.section_id
      weight = expr_code.weight
      if accessor.next
        put_search_index(accessor, section_id, weight)
      else
        put_search_index(index_info.index, section_id, weight)
      end
    end

    def match_resolve_index_expression_data_column(expr_code)
      column = expr_code.value
      index_info = column.find_index(op)
      return if index_info.nil?
      put_search_index(index_info.index, index_info.section_id, expr_code.weight)
    end

    def match_resolve_index_db_obj(db_obj)
      index_info = db_obj.find_index(op)
      return if index_info.nil?
      put_search_index(index_info.index, index_info.section_id, 1)
    end

    def match_resolve_index_accessor(accessor)
      self.flags |= ScanInfo::Flags::ACCESSOR
      index_info = accessor.find_index(op)
      return if index_info.nil?
      if accessor.next
        put_search_index(accessor, index_info.section_id, 1)
      else
        put_search_index(index_info.index, index_info.section_id, 1)
      end
    end

    def call_relational_resolve_index(object)
      case object
      when Accessor
        call_relational_resolve_index_accessor(object)
      when Bulk
        self.query = object
      else
        call_relational_resolve_index_db_obj(object)
      end
    end

    def call_relational_resolve_index_db_obj(db_obj)
      index_info = db_obj.find_index(op)
      return if index_info.nil?
      put_search_index(index_info.index, index_info.section_id, 1)
    end

    def call_relational_resolve_index_accessor(accessor)
      self.flags |= ScanInfo::Flags::ACCESSOR
      index_info = accessor.find_index(op)
      return if index_info.nil?
      put_search_index(index_info.index, index_info.section_id, 1)
    end

    def put_search_index(index, section_id, weight)
      search_index = ScanInfoSearchIndex.new(index, section_id, weight)
      @search_indexes << search_index
    end
  end
end
