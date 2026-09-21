package main

import "virelai/sshlib"

// Local aliases so the server state machine keeps the names it landed
// with. The primitives live in virelai/sshlib so GOSSH.ELF can reuse
// them without a second copy (M71j / ADR 0023).

type sshCipher = sshlib.Cipher
type sshReader = sshlib.Reader
type sshWriter = sshlib.Writer
type AuthKey = sshlib.AuthKey
type serverConfig = sshlib.ServerConfig
type Server = sshlib.Server

const (
	polyTagLen        = sshlib.PolyTagLen
	sshCipherKey      = sshlib.CipherKeyLen
	pktMaxTotal       = sshlib.PktMaxTotal
	alignPlain        = sshlib.AlignPlain
	alignAEAD         = sshlib.AlignAEAD
	identLine         = sshlib.IdentLine
	serverChanID      = sshlib.ServerChanID
	msgDisconnect     = sshlib.MsgDisconnect
	msgIgnore         = sshlib.MsgIgnore
	msgDebug          = sshlib.MsgDebug
	msgServiceRequest = sshlib.MsgServiceRequest
	msgServiceAccept  = sshlib.MsgServiceAccept
	msgKexInit        = sshlib.MsgKexInit
	msgNewKeys        = sshlib.MsgNewKeys
	msgKexECDHInit    = sshlib.MsgKexECDHInit
	msgKexECDHReply   = sshlib.MsgKexECDHReply
	msgUserauthReq    = sshlib.MsgUserauthReq
	msgUserauthFail   = sshlib.MsgUserauthFail
	msgUserauthOK     = sshlib.MsgUserauthOK
	msgChannelOpen    = sshlib.MsgChannelOpen
	msgChannelConfirm = sshlib.MsgChannelConfirm
	msgChannelWindow  = sshlib.MsgChannelWindow
	msgChannelData    = sshlib.MsgChannelData
	msgChannelEOF     = sshlib.MsgChannelEOF
	msgChannelClose   = sshlib.MsgChannelClose
	msgChannelReq     = sshlib.MsgChannelReq
	msgChannelOK      = sshlib.MsgChannelOK
	msgChannelFail    = sshlib.MsgChannelFail
	algoEd25519       = sshlib.AlgoEd25519
	kexCurve          = sshlib.KexCurve
	kexCurveAlias     = sshlib.KexCurveAlias
	cipherOpenSSH     = sshlib.CipherOpenSSH
	compNone          = sshlib.CompNone
	svcUserauth       = sshlib.SvcUserauth
	svcConnection     = sshlib.SvcConnection
	methodNone        = sshlib.MethodNone
	methodPubKey      = sshlib.MethodPubKey
	chanSession       = sshlib.ChanSession
	reqExec           = sshlib.ReqExec
	reqExitStatus     = sshlib.ReqExitStatus
)

func newServer(cfg serverConfig) *Server { return sshlib.NewServer(cfg) }

var (
	parseHex       = sshlib.ParseHex
	parseHex32     = sshlib.ParseHex32
	encodeHex      = sshlib.EncodeHex
	wipe           = sshlib.Wipe
	edDerivePublic = sshlib.EdDerivePublic
	edSign         = sshlib.EdSign
	edVerify       = sshlib.EdVerify
	x25519         = sshlib.X25519
	x25519Base     = sshlib.X25519Base
	sha256Sum      = sshlib.SHA256Sum
	encodePacket   = sshlib.EncodePacket
	decodePacket   = sshlib.DecodePacket
	paddingLen     = sshlib.PaddingLen
	exchangeHash   = sshlib.ExchangeHash
	deriveKey      = sshlib.DeriveKey
	mpint          = sshlib.Mpint
	containsName   = sshlib.ContainsName
	chachaBlock    = sshlib.ChaChaBlock
	poly1305Tag    = sshlib.Poly1305Tag
)
