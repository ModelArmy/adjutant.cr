def attempt_times(n, action)
  attempt = 0
  result = nil
  while attempt < n
    attempt = attempt + 1
    begin
      result = action.call
      return result
    rescue StandardError => e
      raise e if attempt >= n
    end
  end
  result
end
