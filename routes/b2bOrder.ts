/*
 * Copyright (c) 2014-2026 Bjoern Kimminich & the OWASP Juice Shop contributors.
 * SPDX-License-Identifier: MIT
 */

import vm from 'node:vm'
import { type Request, type Response, type NextFunction } from 'express'
// @ts-expect-error FIXME due to non-existing type definitions for notevil
import { eval as safeEval } from 'notevil'

import * as challengeUtils from '../lib/challengeUtils'
import { challenges } from '../data/datacache'
import * as security from '../lib/insecurity'
import * as utils from '../lib/utils'

function isSafeB2bOrderPayload (payload: string): boolean {
  // 1. Must only contain safe characters (alphanumeric, whitespace, and basic safe operators/punctuation).
  // Explicitly excludes backslash \, bracket [ ], backtick ` to prevent evasion, string-construction bypasses, and property-accessing bypasses.
  const allowedChars = /^[a-zA-Z0-9\s;{}()=<>+\-*/!,.:?&|"'%_]+$/
  if (!allowedChars.test(payload)) {
    return false
  }

  // 2. Case-insensitive blocked words
  const blockedWordsLower = [
    'constructor',
    'prototype',
    '__proto__',
    'process',
    'require',
    'global',
    'globalthis',
    'window',
    'document',
    'module',
    'exports',
    'object',
    'reflect',
    'proxy',
    'symbol',
    'eval',
    'exec',
    'spawn',
    'child_process',
    'fs',
    'path',
    'os',
    'vm',
    'safeeval',
    'buffer',
    'import',
    'define',
    'system',
    'mainmodule'
  ]

  const lowercaseInput = payload.toLowerCase()
  if (blockedWordsLower.some(word => lowercaseInput.includes(word))) {
    return false
  }

  // 3. Case-sensitive or mixed-case blocking for Function constructor
  // Allows lowercase 'function' keyword for compatibility, but blocks 'Function', 'FUNCTION', 'fUnCtIoN', etc.
  const dangerousFunctionRegex = /\b(?!(?:function)\b)[Ff][Uu][Nn][Cc][Tt][Ii][Oo][Nn]\b/
  if (dangerousFunctionRegex.test(payload)) {
    return false
  }

  return true
}

export function b2bOrder () {
  return ({ body }: Request, res: Response, next: NextFunction) => {
    if (utils.isChallengeEnabled(challenges.rceChallenge) || utils.isChallengeEnabled(challenges.rceOccupyChallenge)) {
      const orderLinesData = typeof body.orderLinesData === 'string' ? body.orderLinesData : ''
      try {
        if (!isSafeB2bOrderPayload(orderLinesData)) {
          throw new Error('Unsafe input detected.')
        }
        const sandbox = { safeEval, orderLinesData }
        vm.createContext(sandbox)
        vm.runInContext('safeEval(orderLinesData)', sandbox, { timeout: 2000 })
        res.json({ cid: body.cid, orderNo: uniqueOrderNumber(), paymentDue: dateTwoWeeksFromNow() })
      } catch (err) {
        if (utils.getErrorMessage(err).match(/Script execution timed out.*/) != null) {
          challengeUtils.solveIf(challenges.rceOccupyChallenge, () => { return true })
          res.status(503)
          next(new Error('Sorry, we are temporarily not available! Please try again later.'))
        } else {
          challengeUtils.solveIf(challenges.rceChallenge, () => { return utils.getErrorMessage(err) === 'Infinite loop detected - reached max iterations' })
          next(err)
        }
      }
    } else {
      res.json({ cid: body.cid, orderNo: uniqueOrderNumber(), paymentDue: dateTwoWeeksFromNow() })
    }
  }

  function uniqueOrderNumber () {
    return security.hash(`${(new Date()).toString()}_B2B`)
  }

  function dateTwoWeeksFromNow () {
    return new Date(new Date().getTime() + (14 * 24 * 60 * 60 * 1000)).toISOString()
  }
}
