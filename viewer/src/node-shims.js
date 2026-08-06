// Use isomorphic-git's Node build in the browser.
//
// Its browser bundle fails inside pack indexing (a null slice) where the Node
// path works on identical input, so we resolve the Node build and supply the two
// globals it expects. Verified by running the same loader under Node.
import { Buffer } from 'buffer'
import process from 'process'

export { Buffer, process }
