require 'find'
class Cloudinary::Static
  IGNORE_FILES = [".svn", "CVS", "RCS", ".git", ".hg", /^.htaccess/]
  STATIC_IMAGE_DIRS = ["app/assets/images", "public/images"]
  METADATA_FILE = ".cloudinary.static"
  METADATA_TRASH_FILE = ".cloudinary.static.trash"
  
  def self.discover
    ignore_files = Cloudinary.config.ignore_files || IGNORE_FILES 
    relative_dirs = Cloudinary.config.statis_image_dirs || STATIC_IMAGE_DIRS
    dirs = relative_dirs.map{|dir| Rails.root.join(dir)}.select(&:exist?)
    dirs.each do
      |dir|
      dir.find do
        |path|
        file = path.basename.to_s
        if IGNORE_FILES.any?{|pattern| pattern.is_a?(String) ? pattern == file : file.match(pattern)}
          Find.prune
          next
        elsif path.directory?
          next
        else
          relative_path = path.relative_path_from(Rails.root)
          public_path = path.relative_path_from(dir.dirname)
          yield(relative_path, public_path)
        end
      end
    end
  end
  
  UTC = ActiveSupport::TimeZone["UTC"]
  
  def self.metadata_file_path
    Rails.root.join(METADATA_FILE)
  end

  def self.metadata_trash_file_path
    Rails.root.join(METADATA_TRASH_FILE)
  end
  
  def self.metadata(metadata_file = metadata_file_path, hash=true) 
    metadata = []
    if File.exist?(metadata_file)
      IO.foreach(metadata_file) do
        |line|
        line.strip!
        next if line.blank?
        path, public_id, upload_time, version, width, height = line.split("\t")
        metadata << [path, {
          "public_id" => public_id, 
          "upload_time" => UTC.at(upload_time.to_i), 
          "version" => version,
          "width" => width.to_i,
          "height" => height.to_i
        }]
      end
    end
    hash ? Hash[*metadata.flatten] : metadata
  end

  def self.sync(options={})
    options = options.clone
    delete_missing = options.delete(:delete_missing)
    metadata = self.metadata
    found_paths = Set.new
    found_public_ids = Set.new
    metadata_lines = []
    self.discover do
      |path, public_path|
      next if found_paths.include?(path)
      found_paths << path
      data = Rails.root.join(path).read(:mode=>"rb")
      ext = path.extname
      format = ext[1..-1]
      md5 = Digest::MD5.hexdigest(data)
      public_id = "#{public_path.basename(ext)}-#{md5}"
      found_public_ids << public_id
      current_metadata = metadata.delete(public_path.to_s)      
      if current_metadata && current_metadata["public_id"] == public_id # Signature match
        result = current_metadata
      else
        result = Cloudinary::Uploader.upload(Cloudinary::Blob.new(data, :original_filename=>path.to_s),
          options.merge(:format=>format, :public_id=>public_id, :type=>:asset)
        )
      end
      metadata_lines << [public_path, public_id, Time.now.to_i, result["version"], result["width"], result["height"]].join("\t")+"\n"
    end
    File.open(self.metadata_file_path, "w"){|f| f.print(metadata_lines.join)}
    # Files no longer needed 
    trash = metadata.to_a + self.metadata(metadata_trash_file_path, false).reject{|public_path, info| found_public_ids.include?(info["public_id"])} 
    
    if delete_missing
      trash.each do
        |path, info|
        Cloudinary::Uploader.destroy(info["public_id"], options.merge(:type=>:asset))
      end
      FileUtils.rm_f(self.metadata_trash_file_path)
    else
      # Add current removed file to the trash file.
      metadata_lines = trash.map do
        |public_path, info|
        [public_path, info["public_id"], info["upload_time"].to_i, info["version"], info["width"], info["height"]].join("\t")+"\n"
      end
      File.open(self.metadata_trash_file_path, "w"){|f| f.print(metadata_lines.join)}    
    end
  end
end