import fs from 'fs'
import { MerkleTree } from 'merkletreejs'
import keccak256 from 'keccak256'

let addresses
if (fs.existsSync(`./addresses.json`)) {
  addresses = JSON.parse(fs.readFileSync('./addresses.json'))
}

if (!addresses.length) throw Error('No addresses found')

const leaves = addresses.map((address) => keccak256(address))
const tree = new MerkleTree(leaves, keccak256)
const root = tree.getHexRoot()

const whitelist = addresses.map((address) => ({
  address,
  proof: tree.getHexProof(keccak256(address))
}))

if (!fs.existsSync(`./generated`)) {
  fs.mkdirSync('./generated')
}

fs.writeFileSync('./generated/root.json', JSON.stringify(root, null, 2))
fs.writeFileSync('./generated/whitelist.json', JSON.stringify(whitelist, null, 2))
