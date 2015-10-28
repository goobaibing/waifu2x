local __FILE__ = (function() return string.gsub(debug.getinfo(2, 'S').source, "^@", "") end)()
package.path = path.join(path.dirname(__FILE__), "lib", "?.lua;") .. package.path
require 'optim'
require 'xlua'
require 'pl'

require 'w2nn'
local settings = require 'settings'
local srcnn = require 'srcnn'
local minibatch_adam = require 'minibatch_adam'
local iproc = require 'iproc'
local reconstruct = require 'reconstruct'
local compression = require 'compression'
local pairwise_transform = require 'pairwise_transform'
local image_loader = require 'image_loader'

local function save_test_scale(model, rgb, file)
   local up = reconstruct.scale(model, settings.scale, rgb)
   image.save(file, up)
end
local function save_test_jpeg(model, rgb, file)
   local im, count = reconstruct.image(model, rgb)
   image.save(file, im)
end
local function split_data(x, test_size)
   local index = torch.randperm(#x)
   local train_size = #x - test_size
   local train_x = {}
   local valid_x = {}
   for i = 1, train_size do
      train_x[i] = x[index[i]]
   end
   for i = 1, test_size do
      valid_x[i] = x[index[train_size + i]]
   end
   return train_x, valid_x
end
local function make_validation_set(x, transformer, n)
   n = n or 4
   local data = {}
   for i = 1, #x do
      for k = 1, math.max(n / 8, 1) do
	 local xy = transformer(x[i], true, 8)
	 for j = 1, #xy do
	    local x = xy[j][1]
	    local y = xy[j][2]
	    table.insert(data, {x = x:reshape(1, x:size(1), x:size(2), x:size(3)),
				y = y:reshape(1, y:size(1), y:size(2), y:size(3))})
	 end
      end
      xlua.progress(i, #x)
      collectgarbage()
   end
   return data
end
local function validate(model, criterion, data)
   local loss = 0
   for i = 1, #data do
      local z = model:forward(data[i].x:cuda())
      loss = loss + criterion:forward(z, data[i].y:cuda())
      xlua.progress(i, #data)
      if i % 10 == 0 then
	 collectgarbage()
      end
   end
   return loss / #data
end

local function create_criterion(model)
   if reconstruct.is_rgb(model) then
      local offset = reconstruct.offset_size(model)
      local output_w = settings.crop_size - offset * 2
      local weight = torch.Tensor(3, output_w * output_w)
      weight[1]:fill(0.299 * 3) -- R
      weight[2]:fill(0.587 * 3) -- G
      weight[3]:fill(0.114 * 3) -- B
      return w2nn.WeightedMSECriterion(weight):cuda()
   else
      return nn.MSECriterion():cuda()
   end
end
local function transformer(x, is_validation, n, offset)
   x = compression.decompress(x)
   n = n or settings.batch_size;
   if is_validation == nil then is_validation = false end
   local color_noise = nil 
   local overlay = nil
   local active_cropping_ratio = nil
   local active_cropping_tries = nil
   
   if is_validation then
      active_cropping_rate = 0.0
      active_cropping_tries = 0
      color_noise = false
      overlay = false
   else
      active_cropping_rate = settings.active_cropping_rate
      active_cropping_tries = settings.active_cropping_tries
      color_noise = settings.color_noise
      overlay = settings.overlay
   end
   
   if settings.method == "scale" then
      return pairwise_transform.scale(x,
				      settings.scale,
				      settings.crop_size, offset,
				      n,
				      { color_noise = color_noise,
					overlay = overlay,
					random_half = settings.random_half,
					active_cropping_rate = active_cropping_rate,
					active_cropping_tries = active_cropping_tries,
					rgb = (settings.color == "rgb")
				      })
   elseif settings.method == "noise" then
      return pairwise_transform.jpeg(x,
				     settings.category,
				     settings.noise_level,
				     settings.crop_size, offset,
				     n,
				     { color_noise = color_noise,
				       overlay = overlay,
				       active_cropping_rate = active_cropping_rate,
				       active_cropping_tries = active_cropping_tries,
				       random_half = settings.random_half,
				       jpeg_sampling_factors = settings.jpeg_sampling_factors,
				       rgb = (settings.color == "rgb")
				     })
   elseif settings.method == "noise_scale" then
      return pairwise_transform.jpeg_scale(x,
					   settings.scale,
					   settings.category,
					   settings.noise_level,
					   settings.crop_size, offset,
					   n,
					   { color_noise = color_noise,
					     overlay = overlay,
					     jpeg_sampling_factors = settings.jpeg_sampling_factors,
					     random_half = settings.random_half,
					     rgb = (settings.color == "rgb")
					   })
   end
end

local function train()
   local model = srcnn.create(settings.method, settings.backend, settings.color)
   local offset = reconstruct.offset_size(model)
   local pairwise_func = function(x, is_validation, n)
      return transformer(x, is_validation, n, offset)
   end
   local criterion = create_criterion(model)
   local x = torch.load(settings.images)
   local lrd_count = 0
   local train_x, valid_x = split_data(x, math.floor(settings.validation_ratio * #x))
   local adam_config = {
      learningRate = settings.learning_rate,
      xBatchSize = settings.batch_size,
   }
   local ch = nil
   if settings.color == "y" then
      ch = 1
   elseif settings.color == "rgb" then
      ch = 3
   end
   local best_score = 100000.0
   print("# make validation-set")
   local valid_xy = make_validation_set(valid_x, pairwise_func, settings.validation_crops)
   valid_x = nil
   
   collectgarbage()
   model:cuda()
   print("load .. " .. #train_x)
   for epoch = 1, settings.epoch do
      model:training()
      print("# " .. epoch)
      print(minibatch_adam(model, criterion, train_x, adam_config,
			   pairwise_func,
			   {ch, settings.crop_size, settings.crop_size},
			   {ch, settings.crop_size - offset * 2, settings.crop_size - offset * 2}
			  ))
      model:evaluate()
      print("# validation")
      local score = validate(model, criterion, valid_xy)
      if score < best_score then
	 local test_image = image_loader.load_float(settings.test) -- reload
	 lrd_count = 0
	 best_score = score
	 print("* update best model")
	 torch.save(settings.model_file, model)
	 if settings.method == "noise" then
	    local log = path.join(settings.model_dir,
				  ("noise%d_best.png"):format(settings.noise_level))
	    save_test_jpeg(model, test_image, log)
	 elseif settings.method == "scale" then
	    local log = path.join(settings.model_dir,
				  ("scale%.1f_best.png"):format(settings.scale))
	    save_test_scale(model, test_image, log)
	 elseif settings.method == "noise_scale" then
	    local log = path.join(settings.model_dir,
				  ("noise%d_scale%.1f_best.png"):format(settings.noise_level,
									settings.scale))
	    save_test_scale(model, test_image, log)
	 end
      else
	 lrd_count = lrd_count + 1
	 if lrd_count > 5 then
	    lrd_count = 0
	    adam_config.learningRate = adam_config.learningRate * 0.9
	    print("* learning rate decay: " .. adam_config.learningRate)
	 end
      end
      print("current: " .. score .. ", best: " .. best_score)
      collectgarbage()
   end
end
torch.manualSeed(settings.seed)
cutorch.manualSeed(settings.seed)
print(settings)
train()
