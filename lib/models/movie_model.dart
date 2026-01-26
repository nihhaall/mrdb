import 'package:flutter/cupertino.dart';

class Movie {
  final int movId;
  final String title;
  final String img;
  final String year;
  final double rating;
  final DateTime timeStamp;
  final bool delete;

  Movie({
    required this.movId,
    required this.title,
    required this.img,
    required this.year,
    required this.rating,
    required this.timeStamp, required this.delete,

  });

  // copyWith
  Movie copyWith({
    int? id,
    String? title,
    String? img,
    String? year,
    double? rating,
    DateTime? timeStamp,
    bool? delete
  }) {
    return Movie(
      movId: id ?? movId,
      title: title ?? this.title,
      img: img ?? this.img,
      year: year ?? this.year,
      rating: rating ?? this.rating,
      timeStamp: timeStamp??this.timeStamp,
      delete: delete??this.delete
    );
  }

  // fromMap
  factory Movie.fromMap(Map<String, dynamic> map) {
    return Movie(
      movId: map['id'] ?? 0,
      title: map['title'] ?? '',
      img: map['img'] ?? '',
      year: map['year'] ?? '',
      rating: (map['rating'] ?? 0).toDouble(),
      timeStamp: map['timeStamp'] ?? DateTime.now(),
      delete: map['delete']??false
    );
  }

  // toMap
  Map<String, dynamic> toMap() {
    return {
      'id': movId,
      'title': title,
      'img': img,
      'year': year,
      'rating': rating,
      'timeStamp': timeStamp,
      'delete': delete
    };
  }
}
