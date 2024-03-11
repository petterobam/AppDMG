//
//  Allocator.swift
//
//
//  Created by Chocoford on 2023/12/1.
//

import Foundation

public enum DirectoryName: String {
    case DSDB
}

public struct Allocator {
    public var blocks = [(offset: UInt32, size: UInt32)]()
    public var directories = [(name: DirectoryName, id: UInt32)]()
    public var freeList = [[UInt32]]()
    
    // dump
    var _unnamed1: UInt32
    
    internal init(
        blocks: [(offset: UInt32, size: UInt32)] = [(offset: UInt32, size: UInt32)](),
        directories: [(name: DirectoryName, id: UInt32)] = [(name: DirectoryName, id: UInt32)](),
        freeList: [[UInt32]] = [[UInt32]](),
        _unnamed1: UInt32
    ) {
        self.blocks = blocks
        self.directories = directories
        self.freeList = freeList
        self._unnamed1 = _unnamed1
    }
    
    public init(data: Data, header: Header) throws {
        var offset = Int(header.offset1) + 4
        let n = data.readInteger(at: offset, as: UInt32.self, endianness: .big)
        offset += MemoryLayout<UInt32>.size
        
        self._unnamed1 = data.readInteger(at: offset, as: UInt32.self, endianness: .big)
        offset += MemoryLayout<UInt32>.size

        self.blocks.append(
            contentsOf: data.readIntegers(
                at: offset,
                count: Int(n),
                as: UInt32.self,
                endianness: .big
            )
            .map { Allocator.decodeOffsetAndSize($0) }
        )
        offset += Int(n) * MemoryLayout<UInt32>.size
        
        let remaining = 256 - (n % 256)
        offset += Int(remaining * 4)
        
        // Read Directories
        let directoriesCount = data.readInteger(at: offset, as: UInt32.self, endianness: .big)

        offset += MemoryLayout<UInt32>.size
        
        for _ in 0 ..< directoriesCount {
            let nameLength = Int(data.readUInt8(at: offset))
            offset += MemoryLayout<UInt8>.size
            
            let name = data.readString(at: offset, length: nameLength, encoding: .utf8) ?? ""
            offset += nameLength * MemoryLayout<UInt8>.size
            
            let id = data.readInteger(at: offset, as: UInt32.self, endianness: .big)
            offset += MemoryLayout<UInt32>.size

            guard let dirName = DirectoryName(rawValue: name) else {
                throw DSStoreError(message: "Unknown directory name - \(name)")
            }
            
            self.directories.append((name: dirName, id: id))
        }
        
        // Read FreeList
        for _ in 0 ..< 32 {
            let n = data.readInteger(at: offset, as: UInt32.self, endianness: .big)
            offset += MemoryLayout<UInt32>.size
            self.freeList.append(
                data.readIntegers(at: offset, count: Int(n), as: UInt32.self, endianness: .big)
            )
            offset += Int(n) * MemoryLayout<UInt32>.size
        }
        
    }
    
    static func create() -> Allocator {
        Allocator(
            blocks: [(offset: 8192, size: 2048), (offset: 64, size: 32), (offset: 4096, size: 4096)],
            directories: [(name: .DSDB, id: 1)],
            freeList: [
                [], [], [], [], [], [32, 96], [], [128], [256], [512], [1024], [2048, 10240], [12288], [], [16384], [32768], [65536], [131072], [262144], [524288], [1048576], [2097152], [4194304], [8388608], [16777216], [33554432], [67108864], [134217728], [268435456], [536870912], [1073741824], []
            ],
            _unnamed1: 0
        )
    }

    
    func constructBuffer(header: Header) throws -> [BufferConstruction] {
        var constructions: [BufferConstruction] = []
        
        var buffer: [UInt8] = []
        
        // block counts
        buffer.append(
            contentsOf: UInt32(self.blocks.count).toBytes(endianness: .big)
        )
        // _unnamed1
        buffer.append(
            contentsOf: self._unnamed1.toBytes(endianness: .big)
        )
        
        // block_addresses
        buffer.append(contentsOf: self.blocks.flatMap {
             Allocator
                 .encodeOffsetAndSize(offset: $0.offset, size: $0.size)
                 .toBytes(endianness: .big)
         })
        
        buffer.append(contentsOf: Array<UInt8>.init(repeating: 0, count: (256 - self.blocks.count % 256) * 4))
        

        // directories
        buffer.append(
            contentsOf: UInt32(self.directories.count).toBytes(endianness: .big)
        )
                
        for directory in directories {
            // name length
            buffer.append(
                contentsOf: UInt8(directory.name.rawValue.count).toBytes(endianness: .big)
            )
            guard let data = directory.name.rawValue.data(using: .utf8) else {
                throw DSStoreError(message: "Invalid directory name")
            }
            buffer.append(
                contentsOf: [UInt8](data)
            )
            buffer.append(
                contentsOf: directory.id.toBytes(endianness: .big)
            )
        }
        
        // FreeList
        for freeListItem in freeList {
            buffer.append(contentsOf: UInt32(freeListItem.count).toBytes(endianness: .big))
            buffer.append(contentsOf: freeListItem.flatMap { $0.toBytes(endianness: .big) })
        }
        
        constructions.append(BufferConstruction(buffer: buffer, start: Int(header.offset1) + 4))
        
        return constructions
    }
    
    
    static func encodeOffsetAndSize(offset: UInt32, size: UInt32) -> UInt32 {
        let offsetPart: UInt32 = offset & ~0x1F
        let sizePart: UInt32 = UInt32(log2(Double(size))) & 0x1F
        
        return offsetPart | sizePart
    }

    
    public static func decodeOffsetAndSize(_ value: UInt32) -> (offset: UInt32, size: UInt32) {
        let offset: UInt32 = value & ~0x1F
        let size: UInt32 = 1 << (value & 0x1F)
        
        return (offset: offset, size: size)
    }
}

extension Allocator: Hashable {
    public static func == (lhs: Allocator, rhs: Allocator) -> Bool {
        lhs.blocks.count == rhs.blocks.count &&
        lhs.blocks.enumerated().allSatisfy({ i, value in
            let (offset, size) = value
            return offset == rhs.blocks[i].offset && size == rhs.blocks[i].size
        }) &&
        lhs.directories.count == rhs.directories.count &&
        lhs.directories.enumerated().allSatisfy({ i, value in
            let (name, id) = value
            return name == rhs.directories[i].name && id == rhs.directories[i].id
        }) &&
        lhs.freeList == rhs.freeList
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(blocks.map({$0.offset}))
        hasher.combine(blocks.map({$0.size}))
        hasher.combine(directories.map({$0.name}))
        hasher.combine(directories.map({$0.id}))
        hasher.combine(freeList)
    }
}
