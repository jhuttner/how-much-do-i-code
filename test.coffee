app = require './app.coffee'

exports['getDayName'] = (test) ->
  test.expect 1
  result = app.getDayName 1326438386
  test.strictEqual 'January 13', result
  test.done()
