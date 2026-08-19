/*
 * Copyright (c) 2014-2026 Bjoern Kimminich & the OWASP Juice Shop contributors.
 * SPDX-License-Identifier: MIT
 */

import fs from 'node:fs'
import { Readable } from 'node:stream'
import { finished } from 'node:stream/promises'
import { type Request, type Response, type NextFunction } from 'express'
import dns from 'node:dns/promises'

import * as security from '../lib/insecurity'
import { UserModel } from '../models/user'
import * as utils from '../lib/utils'
import logger from '../lib/logger'

function isPrivateIp (ip: string): boolean {
  if (!ip) return true

  // IPv4 check
  const ipv4Regex = /^(\d+)\.(\d+)\.(\d+)\.(\d+)$/
  const ipv4Match = ip.match(ipv4Regex)
  if (ipv4Match) {
    const parts = ipv4Match.slice(1).map(Number)
    if (parts.some(p => p < 0 || p > 255)) return true // invalid IP
    const [p0, p1, p2, p3] = parts

    // 127.0.0.0/8 (Loopback)
    if (p0 === 127) return true
    // 10.0.0.0/8 (Private)
    if (p0 === 10) return true
    // 172.16.0.0/12 (Private)
    if (p0 === 172 && p1 >= 16 && p1 <= 31) return true
    // 192.168.0.0/16 (Private)
    if (p0 === 192 && p1 === 168) return true
    // 169.254.0.0/16 (Link-local)
    if (p0 === 169 && p1 === 254) return true
    // 0.0.0.0/8 (Broadcast/any)
    if (p0 === 0) return true
    // 224.0.0.0/4 (Multicast)
    if (p0 >= 224 && p0 <= 239) return true
    // 255.255.255.255 (Broadcast)
    if (p0 === 255 && p1 === 255 && p2 === 255 && p3 === 255) return true

    return false
  }

  // IPv6 check
  const lowerIp = ip.toLowerCase().trim()
  
  // Loopback (::1) and Unspecified (::)
  if (lowerIp === '::1' || lowerIp === '::' || lowerIp === '0:0:0:0:0:0:0:1' || lowerIp === '0:0:0:0:0:0:0:0') {
    return true
  }

  // IPv4-mapped IPv6 addresses (e.g. ::ffff:127.0.0.1)
  if (lowerIp.startsWith('::ffff:')) {
    const mappedPart = ip.slice(7)
    if (mappedPart.includes('.')) {
      return isPrivateIp(mappedPart)
    }
  }

  // Unique Local Addresses (ULA): fc00::/7 (starts with fc or fd)
  if (lowerIp.startsWith('fc') || lowerIp.startsWith('fd')) return true

  // Link-local: fe80::/10 (starts with fe8, fe9, fea, feb)
  if (lowerIp.startsWith('fe8') || lowerIp.startsWith('fe9') || lowerIp.startsWith('fea') || lowerIp.startsWith('feb')) return true

  // Multicast: ff00::/8 (starts with ff)
  if (lowerIp.startsWith('ff')) return true

  return false
}

export function profileImageUrlUpload () {
  return async (req: Request, res: Response, next: NextFunction) => {
    if (req.body.imageUrl !== undefined) {
      const url = req.body.imageUrl
      if (typeof url !== 'string') {
        next(new Error('Blocked illegal activity'))
        return
      }
      if (url.match(/(.)*solve\/challenges\/server-side(.)*/) !== null) req.app.locals.abused_ssrf_bug = true
      const loggedInUser = security.authenticatedUsers.get(req.cookies.token)
      if (loggedInUser) {
        try {
          let parsedUrl: URL
          try {
            parsedUrl = new URL(url)
          } catch {
            throw new Error('SSRF_DETECTION: Invalid URL')
          }

          if (parsedUrl.protocol !== 'http:' && parsedUrl.protocol !== 'https:') {
            throw new Error('SSRF_DETECTION: Only HTTP and HTTPS protocols are allowed')
          }

          let hostname = parsedUrl.hostname
          if (!hostname) {
            throw new Error('SSRF_DETECTION: Invalid hostname')
          }
          if (hostname.startsWith('[') && hostname.endsWith(']')) {
            hostname = hostname.slice(1, -1)
          }

          let addresses: string[] = []
          try {
            const lookupResult = await dns.lookup(hostname, { all: true })
            addresses = lookupResult.map(r => r.address)
          } catch (err) {
            throw new Error('SSRF_DETECTION: Could not resolve hostname')
          }

          for (const ip of addresses) {
            if (isPrivateIp(ip)) {
              throw new Error('SSRF_DETECTION: Blocked illegal activity')
            }
          }

          const response = await fetch(url)
          if (!response.ok || !response.body) {
            throw new Error('url returned a non-OK status code or an empty body')
          }
          const ext = ['jpg', 'jpeg', 'png', 'svg', 'gif'].includes(url.split('.').slice(-1)[0].toLowerCase()) ? url.split('.').slice(-1)[0].toLowerCase() : 'jpg'
          const fileStream = fs.createWriteStream(`frontend/dist/frontend/assets/public/images/uploads/${loggedInUser.data.id}.${ext}`, { flags: 'w' })
          await finished(Readable.fromWeb(response.body as any).pipe(fileStream))
          const user = await UserModel.findByPk(loggedInUser.data.id)
          await user?.update({ profileImage: `/assets/public/images/uploads/${loggedInUser.data.id}.${ext}` })
        } catch (error: any) {
          if (error && error.message && error.message.startsWith('SSRF_DETECTION:')) {
            next(error)
            return
          }
          try {
            const user = await UserModel.findByPk(loggedInUser.data.id)
            await user?.update({ profileImage: url })
            logger.warn(`Error retrieving user profile image: ${utils.getErrorMessage(error)}; using image link directly`)
          } catch (error) {
            next(error)
            return
          }
        }
      } else {
        next(new Error('Blocked illegal activity by ' + req.socket.remoteAddress))
        return
      }
    }
    res.location(process.env.BASE_PATH + '/profile')
    res.redirect(process.env.BASE_PATH + '/profile')
  }
}
