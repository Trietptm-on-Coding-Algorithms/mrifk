{-
Mrifk, a decompiler for Glulx story files.
Copyright 2004 Ben Rudiak-Gould.

This program is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You can read the GNU General Public License at this URL:
     http://www.gnu.org/copyleft/gpl.html
-}


module Mrifk_disasm (
	disasmRoutines
) where


import Mrifk_storyfile
import Mrifk_code

import Numeric (showHex)
import Control.Monad (replicateM,liftM)
import Data.Bits ((.&.),shiftR)


{------------------------------- disassembly ----------------------------------}


disasmRoutines = do
  eos <- isEOS
  if eos then return [] else do
  type_ <- peekUByte
  if type_ `elem` [0xC0,0xC1] then
     do r  <- disasmRoutine
        rs <- disasmRoutines
        return (r:rs)
   else if type_ == 0x31 then
     -- hack: skip over unreachable trailing "return" statements generated by Inform
     getBytes 3 >> disasmRoutines
   else
     do pos <- getPos
        error ("Unexpected byte during code disassembly: " ++ showHex type_ (" at offset " ++ showHex pos ""))


disasmRoutine = do
  addr  <- getPos
  type_ <- getUByte
  localTypes <- disasmLocalTypes
  body       <- disasmInstrs
  return (addr,type_,localTypes,body)

disasmLocalTypes = do
  type_ <- getUByte
  count <- getUByte
  if type_ == 0 && count == 0
    then return []
    else do rest <- disasmLocalTypes
            return (replicate count type_ ++ rest)


disasmInstrs =
  do eof <- endOfFunction
     if eof then
       return []
      else
       do addr  <- getPos
          instr <- disasmInstr
          rest  <- disasmInstrs
          return (Label addr Multi : instr : rest)

endOfFunction =
  do eos <- isEOS
     if eos then return True
            else do byte <- peekUByte
                    return (byte >= 0xC0)


disasmInstr = do
  opcode1 <- peekUByte
  opcode  <- if opcode1 < 0x80 then
               getUByte
             else if opcode1 < 0xC0 then
               liftM (subtract 0x8000) getUWord
             else
               liftM (+ 0x40000000) getDword
  case lookup opcode opcodes of
    Just info -> disasmInstr' info
    Nothing   -> error ("Invalid Glulx opcode " ++ showHex opcode "")


disasmInstr' info@(_,loads,stores,branches,_) = do
  let operandCount = loads+stores+branches
      operandByteCount = (operandCount+1) `div` 2
  x <- replicateM operandByteCount getOperandByte
  let operandDescs = take operandCount $ concat x
  operands  <- mapM getOperand operandDescs
  endAddr   <- getPos
  let operands' = zipWith ($) (replicate (loads+stores) id ++ repeat (cvtBranch endAddr)) operands
  return (GInstr (cvtInfo info) operands')

cvtBranch endAddr (Imm 0) = Imm 0
cvtBranch endAddr (Imm 1) = Imm 1
cvtBranch endAddr (Imm n) = Imm (endAddr + n - 2)
cvtBranch endAddr x = error "Unexpected branch target mode"

-- Hack to handle jumpabs, which takes a target label but doesn't
-- follow the format rule of other branch instructions
cvtInfo ("jumpabs",1,0,0,type_) = ("jumpabs",0,0,1,type_)
cvtInfo x = x


getOperandByte = do
  x <- getUByte
  return [x .&. 15, x `shiftR` 4]

getOperand 0  = return (Imm 0)
getOperand 1  = liftM Imm getSByte
getOperand 2  = liftM Imm getSWord
getOperand 3  = liftM Imm getDword
getOperand 5  = liftM Mem getUByte
getOperand 6  = liftM Mem getUWord
getOperand 7  = liftM Mem getDword
getOperand 8  = return SP
getOperand 9  = liftM Local getUByte
getOperand 10 = liftM Local getUWord
getOperand 11 = liftM Local getDword
getOperand 13 = liftM (Mem . (+ hdrRAMStart)) getUByte
getOperand 14 = liftM (Mem . (+ hdrRAMStart)) getUWord
getOperand 15 = liftM (Mem . (+ hdrRAMStart)) getDword


opcodes =
 [(0x00,("nop",		0,0,0,	OSpecial)),
  (0x10,("add",		2,1,0,	OBinary (NormalOp " + " 5))),
  (0x11,("sub",		2,1,0,	OBinary (NormalOp " - " 5))),
  (0x12,("mul",		2,1,0,	OBinary (NormalOp " * " 6))),
  (0x13,("div",		2,1,0,	OBinary (NormalOp " / " 6))),
  (0x14,("mod",		2,1,0,	OBinary (NormalOp " % " 6))),
  (0x15,("neg",		1,1,0,	OSpecial)),
  (0x18,("bitand",	2,1,0,	OBinary (NormalOp " & " 6))),
  (0x19,("bitor",	2,1,0,	OBinary (NormalOp " | " 6))),
  (0x1A,("bitxor",	2,1,0,	OSpecial)),
  (0x1B,("bitnot",	1,1,0,	OSpecial)),
  (0x1C,("shiftl",	2,1,0,	OSpecial)),
  (0x1D,("sshiftr",	2,1,0,	OSpecial)),
  (0x1E,("ushiftr",	2,1,0,	OSpecial)),
  (0x20,("jump",	0,0,1,	OJump)),
  (0x22,("jz",		1,0,1,	OJCond binopEQ)),
  (0x23,("jnz",		1,0,1,	OJCond binopNE)),
  (0x24,("jeq",		2,0,1,	OJCond binopEQ)),
  (0x25,("jne",		2,0,1,	OJCond binopNE)),
  (0x26,("jlt",		2,0,1,	OJCond binopLT)),
  (0x27,("jge",		2,0,1,	OJCond binopGE)),
  (0x28,("jgt",		2,0,1,	OJCond binopGT)),
  (0x29,("jle",		2,0,1,	OJCond binopLE)),
  (0x2A,("jltu",	2,0,1,	OSpecial)),
  (0x2B,("jgeu",	2,0,1,	OSpecial)),
  (0x2C,("jgtu",	2,0,1,	OSpecial)),
  (0x2D,("jleu",	2,0,1,	OSpecial)),
  (0x30,("call",	2,1,0,	OCall)),
  (0x31,("return",	1,0,0,	OReturn)),
  (0x32,("catch",	0,1,1,	OSpecial)),
  (0x33,("throw",	2,0,0,	OSpecial)),
  (0x34,("tailcall",	2,0,0,	OSpecial)),
  (0x40,("copy",	1,1,0,	OCopy)),
  (0x41,("copys",	1,1,0,	OSpecial)),
  (0x42,("copyb",	1,1,0,	OSpecial)),
  (0x44,("sexs",	1,1,0,	OSpecial)),
  (0x45,("sexb",	1,1,0,	OSpecial)),
  (0x48,("aload",	2,1,0,	OBinary (NormalOp "-->" 7))),
  (0x49,("aloads",	2,1,0,	OSpecial)),
  (0x4A,("aloadb",	2,1,0,	OBinary (NormalOp "->" 7))),
  (0x4B,("aloadbit",	2,1,0,	OALoadBit)),
  (0x4C,("astore",	3,0,0,	OAStore)),
  (0x4D,("astores",	3,0,0,	OSpecial)),
  (0x4E,("astoreb",	3,0,0,	OAStoreB)),
  (0x4F,("astorebit",	3,0,0,	OAStoreBit)),
  (0x50,("stkcount",	0,1,0,	OSpecial)),
  (0x51,("stkpeek",	1,1,0,	OSpecial)),
  (0x52,("stkswap",	0,0,0,	OStkSwap)),
  (0x53,("stkroll",	2,0,0,	OSpecial)),
  (0x54,("stkcopy",	1,0,0,	OSpecial)),
  (0x70,("streamchar",	1,0,0,	OStreamChar)),
  (0x71,("streamnum",	1,0,0,	OStreamNum)),
  (0x72,("streamstr",	1,0,0,	OStreamStr)),
  (0x73,("streamunichar",       1,0,0,  OStreamChar)),
  (0x100,("gestalt",	2,1,0,	OSpecial)),
  (0x101,("debugtrap",	1,0,0,	OSpecial)),
  (0x102,("getmemsize",	0,1,0,	OSpecial)),
  (0x103,("setmemsize",	1,1,0,	OSpecial)),
  (0x104,("jumpabs",	1,0,0,	OSpecial)),
  (0x110,("random",	1,1,0,	OSpecial)),
  (0x111,("setrandom",	1,0,0,	OSpecial)),
  (0x120,("quit",	0,0,0,	OSpecial)),
  (0x121,("verify",	0,1,0,	OSpecial)),
  (0x122,("restart",	0,0,0,	OSpecial)),
  (0x123,("save",	1,1,0,	OSpecial)),
  (0x124,("restore",	1,1,0,	OSpecial)),
  (0x125,("saveundo",	0,1,0,	OSpecial)),
  (0x126,("restoreundo",0,1,0,	OSpecial)),
  (0x127,("protect",	2,0,0,	OSpecial)),
  (0x130,("glk",	2,1,0,	OGlk)),
  (0x140,("getstringtbl",0,1,0,	OSpecial)),
  (0x141,("setstringtbl",1,0,0,	OSpecial)),
  (0x148,("getiosys",	0,2,0,	OSpecial)),
  (0x149,("setiosys",	2,0,0,	OSpecial)),
  (0x150,("linearsearch",7,1,0,	OSpecial)),
  (0x151,("binarysearch",7,1,0,	OSpecial)),
  (0x152,("linkedsearch",6,1,0,	OSpecial)),
  (0x160,("callf",	1,1,0,	OCallI)),
  (0x161,("callfi",	2,1,0,	OCallI)),
  (0x162,("callfii",	3,1,0,	OCallI)),
  (0x163,("callfiii",	4,1,0,	OCallI)),
  (0x170,("mzero",	2,0,0,	OSpecial)),
  (0x171,("mcopy",	3,0,0,	OSpecial)),
  (0x178,("malloc",	1,1,0,	OSpecial)),
  (0x179,("mfree",	1,0,0,	OSpecial)),
  (0x180,("accelfunc",	2,0,0,	OSpecial)),
  (0x181,("accelparam",	2,0,0,	OSpecial)),
  (0x190,("numtof",	1,1,0,	OSpecial)),
  (0x191,("ftonumz",	1,1,0,	OSpecial)),
  (0x192,("ftonumn",	1,1,0,	OSpecial)),
  (0x198,("ceil",	1,1,0,	OSpecial)),
  (0x199,("floor",	1,1,0,	OSpecial)),
  (0x1A0,("fadd",	2,1,0,	OBinary (NormalOp " + " 5))),
  (0x1A1,("fsub",	2,1,0,	OBinary (NormalOp " - " 5))),
  (0x1A2,("fmul",	2,1,0,	OBinary (NormalOp " * " 6))),
  (0x1A3,("fdiv",	2,1,0,	OBinary (NormalOp " / " 6))),
  (0x1A4,("fmod",	2,2,0,	OBinary (NormalOp " % " 6))),
  (0x1A8,("sqrt",	1,1,0,	OSpecial)),
  (0x1A9,("exp",	1,1,0,	OSpecial)),
  (0x1AA,("log",	1,1,0,	OSpecial)),
  (0x1AB,("pow",	2,1,0,	OSpecial)),
  (0x1B0,("sin",	1,1,0,	OSpecial)),
  (0x1B1,("cos",	1,1,0,	OSpecial)),
  (0x1B2,("tan",	1,1,0,	OSpecial)),
  (0x1B3,("asin",	1,1,0,	OSpecial)),
  (0x1B4,("acos",	1,1,0,	OSpecial)),
  (0x1B5,("atan",	1,1,0,	OSpecial)),
  (0x1B6,("atan2",	2,1,0,	OSpecial)),
  (0x1C0,("jfeq",	3,0,1,	OSpecial)),
  (0x1C1,("jfne",	3,0,1,	OSpecial)),
  (0x1C2,("jflt",	2,0,1,	OJCond binopLT)),
  (0x1C3,("jfle",	2,0,1,	OJCond binopLE)),
  (0x1C4,("jfgt",	2,0,1,	OJCond binopGT)),
  (0x1C5,("jfge",	2,0,1,	OJCond binopGE)),
  (0x1C8,("jisnan",	1,0,1,	OSpecial)),
  (0x1C9,("jisinf",	1,0,1,	OSpecial)),
-- Support the FyreVM specific opcode based on https://github.com/ChicagoDave/fyrevm-dotnet/blob/master/Opcodes.cs. 0x1000 to 0x10FF were reserved for this usage in version 3.1.2 of the Glulx specification.
  (0x1000,("fyrecall",	3,1,0,	OSpecial)),
-- Support the @parchment extension by Dannii Willis based on draft specification here http://curiousdannii.github.io/if/op-parchment.html which officially took this opcode in version 3.1.2 of the Glulx specification. 0x1100 to 0x11FF are reserved for his usage.
  (0x1110,("parchment",	2,1,0,	OSpecial)),
-- Support Andrew Plotkin's iOS extensions... 0x1200 to 0x12FF are reserved for this purpose in version 3.1.2 but any specification or code relating to these doesn't seem to be public.
-- Support Git specific opcodes based on https://github.com/DavidKinder/Git/blob/master/opcodes.c and https://github.com/DavidKinder/Git/blob/master/opcodes.h, 0x7900 to 0x79FF are reserved for these as of 1.3.2
  (0x7940,("setcacheram",	1,0,0,	OSpecial)),
  (0x7941,("prunecache",	2,0,0,	OSpecial))]